defmodule Atoll.Identity.WebHandleChanges do
  @moduledoc "Reconciles an owner-updated did:web document with the local account handle."
  import Ecto.Query
  alias Atoll.{CBOR, Repo, Syntax}
  alias Atoll.Accounts.{Profile, Signup}
  alias Atoll.Identity.{Handle, HandleChanges, HandleReservation, Observation, Resolver}
  alias Atoll.Repositories.{Events, Head}
  alias Atoll.Identity.HandleAuthorization

  def update(token, handle, opts \\ []) do
    with false <- Repo.in_transaction?(),
         true <- Syntax.handle?(handle) and handle == String.downcase(handle),
         {:ok, _} <- Resolver.resolution_url("did:web:" <> handle),
         {:ok, %{did: "did:web:" <> _} = head} <- HandleAuthorization.authenticate(token),
         :ok <- HandleAuthorization.allowed(token, head),
         %Profile{} = prior <- Repo.get(Profile, head.did),
         prior_observation = Repo.get(Observation, head.did),
         {:ok, identity} <- Resolver.resolve(head.did, Keyword.put(opts, :force_refresh, true)),
         :ok <- matches(identity, head, handle),
         :ok <- forward(handle, head.did, opts) do
      Repo.transaction(fn ->
        Events.lock!()

        current =
          Repo.one(from h in Head, where: h.did == ^head.did, lock: "FOR UPDATE") ||
            Repo.rollback(:account_not_found)

        unwrap!(HandleAuthorization.authenticate(token))
        check!(HandleAuthorization.allowed(token, current))
        check!(matches(identity, current, handle))
        profile = Repo.get(Profile, head.did) || Repo.rollback(:account_not_found)
        if Repo.get_by(HandleReservation, did: head.did), do: Repo.rollback(:plc_update_pending)

        cond do
          profile.handle == handle ->
            HandleAuthorization.audit!(token, profile, handle)
            :unchanged

          profile.handle != prior.handle ->
            Repo.rollback(:stale_identity_refresh)

          Repo.get(Observation, head.did) != prior_observation ->
            Repo.rollback(:stale_identity_refresh)

          HandleChanges.claimed?(handle) ->
            Repo.rollback(:handle_not_available)

          true ->
            profile |> Ecto.Changeset.change(handle: handle) |> Repo.update!()
            HandleAuthorization.audit!(token, profile, handle)

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

            Repo.insert!(%Observation{did: head.did, handle: handle, fingerprint: fingerprint},
              on_conflict: {:replace, [:handle, :fingerprint]},
              conflict_target: [:did]
            )

            Events.append!(:identity, current, %{"handle" => handle})
            :completed
        end
      end)
    else
      true -> {:error, :plc_update_inside_transaction}
      false -> {:error, :invalid_handle}
      nil -> {:error, :account_not_found}
      {:error, _} = error -> error
      _ -> {:error, :invalid_handle_update}
    end
  end

  defp matches(identity, head, handle) do
    if identity.claimed_handle == handle and identity.pds == AtollWeb.Endpoint.url() and
         identity.signing_key.curve == head.curve and
         identity.signing_key.public == head.public_key,
       do: :ok,
       else: {:error, :invalid_handle_update}
  end

  defp forward(handle, did, opts) do
    if Signup.hosted_handle?(handle) or
         Handle.resolve(handle, Keyword.put(opts, :force_refresh, true)) == {:ok, did},
       do: :ok,
       else: {:error, :unverified_handle}
  end

  defp check!(:ok), do: :ok
  defp check!({:error, reason}), do: Repo.rollback(reason)
  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
