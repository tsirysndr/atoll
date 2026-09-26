defmodule Atoll.Identity.Updates do
  @moduledoc """
  Internal refresh of identity observations for hosted repositories.

  Resolves outside database locks, verifies the handle's forward claim, then
  atomically stores the observation and emits an identity event. A failed DID
  lookup leaves the previous observation intact. Unverified handles are reported
  as handle.invalid. Observations do not change repository keys or hosting status.
  Callers authorize refreshes; an opt-in worker schedules periodic refreshes.
  Owners can request an authenticated refresh; identity mutation APIs are pending.
  """
  import Ecto.Query
  alias Atoll.{CBOR, Repo, Repositories}
  alias Atoll.Identity.{Handle, Observation, Resolver}
  alias Atoll.Repositories.{Events, Head}

  def refresh(did, opts \\ []) do
    with {:ok, result} <- refresh_result(did, opts, nil), do: {:ok, result.outcome}
  end

  def refresh_authenticated(token, params, opts \\ [])

  def refresh_authenticated(token, %{"identifier" => identifier} = params, opts)
      when map_size(params) == 1 do
    opts = Keyword.put(opts, :force_refresh, true)

    with {:ok, head} <- Atoll.Accounts.Sessions.authenticate_management(token),
         :ok <- own_identifier(identifier, head.did, opts),
         {:ok, result} <- refresh_result(head.did, opts, token) do
      {:ok, result.info}
    end
  end

  def refresh_authenticated(_, _, _), do: {:error, :invalid_request}

  defp own_identifier(identifier, did, opts) do
    cond do
      identifier == did ->
        :ok

      Atoll.Syntax.did?(identifier) ->
        {:error, :forbidden}

      Atoll.Syntax.handle?(identifier) ->
        case Handle.resolve(identifier, opts) do
          {:ok, ^did} -> :ok
          {:ok, _} -> {:error, :forbidden}
          _ -> {:error, :handle_not_found}
        end

      true ->
        {:error, :invalid_request}
    end
  end

  defp refresh_result(did, opts, token) do
    opts = Keyword.put(opts, :force_refresh, true)

    with {:ok, _} <- Repositories.get_head(did) do
      prior = Repo.get(Observation, did)

      with {:ok, identity} <- Resolver.resolve(did, Keyword.put(opts, :force_refresh, true)) do
        handle =
          if is_binary(identity.claimed_handle) and
               Handle.resolve(identity.claimed_handle, opts) == {:ok, did},
             do: identity.claimed_handle,
             else: "handle.invalid"

        fingerprint =
          :crypto.hash(
            :sha256,
            CBOR.encode!(%{
              "handle" => handle,
              "claimedHandle" => identity.claimed_handle,
              "pds" => identity.pds,
              "curve" => Atom.to_string(identity.signing_key.curve),
              "key" => %CBOR.Bytes{data: identity.signing_key.public}
            })
          )

        Repo.transaction(fn ->
          Events.lock!()
          head = Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE")
          unless head, do: Repo.rollback(:not_found)

          if token do
            case Atoll.Accounts.Sessions.authenticate_management(token) do
              {:ok, %{did: ^did}} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end
          end

          current = Repo.get(Observation, did)

          outcome =
            cond do
              current && current.fingerprint == fingerprint ->
                :unchanged

              current != prior ->
                Repo.rollback(:stale_identity_refresh)

              true ->
                Repo.insert!(%Observation{did: did, handle: handle, fingerprint: fingerprint},
                  on_conflict: {:replace, [:handle, :fingerprint]},
                  conflict_target: [:did]
                )

                Events.append!(:identity, head, %{"handle" => handle})
                :published
            end

          %{outcome: outcome, info: %{did: did, handle: handle, didDoc: identity.document}}
        end)
      end
    end
  end
end
