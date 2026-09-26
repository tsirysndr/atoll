defmodule Atoll.Identity.Updates do
  @moduledoc """
  Internal refresh of identity observations for hosted repositories.

  Resolves outside database locks, verifies the handle's forward claim, then
  atomically stores the observation and emits an identity event. A failed DID
  lookup leaves the previous observation intact. Unverified handles are reported
  as handle.invalid. Observations do not change repository keys or hosting status.
  Callers authorize refreshes; an opt-in worker schedules periodic refreshes.
  Authenticated identity mutation APIs are pending.
  """
  import Ecto.Query
  alias Atoll.{CBOR, Repo, Repositories}
  alias Atoll.Identity.{Handle, Observation, Resolver}
  alias Atoll.Repositories.{Events, Head}

  def refresh(did, opts \\ []) do
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
          current = Repo.get(Observation, did)

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
        end)
      end
    end
  end
end
