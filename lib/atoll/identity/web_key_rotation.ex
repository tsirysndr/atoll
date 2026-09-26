defmodule Atoll.Identity.WebKeyRotation do
  @moduledoc "Operator reconciliation of a did:web signing key already published in its DID document."
  import Ecto.Query
  alias Atoll.{CBOR, Multikey, Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{Profile, Signup}
  alias Atoll.Identity.{Handle, HandleReservation, Observation, Resolver}
  alias Atoll.Repositories.{Events, Head}

  def rotate(did, expected, key, opts \\ [])

  def rotate("did:web:" <> _ = did, expected, %SigningKey{} = key, opts) do
    with false <- Repo.in_transaction?(),
         {:ok, _} <- Multikey.from_did_key(expected),
         {:ok, derived} <- SigningKey.from_private(key.curve, key.private),
         true <- derived.public == key.public,
         %Head{} = prior <- Repo.get(Head, did),
         :ok <- expected_key(prior, expected),
         %Profile{} = profile <- Repo.get(Profile, did),
         observation = Repo.get(Observation, did),
         {:ok, identity} <- Resolver.resolve(did, Keyword.put(opts, :force_refresh, true)),
         true <- identity.signing_key == %{curve: key.curve, public: key.public},
         true <-
           identity.pds == AtollWeb.Endpoint.url() and identity.claimed_handle == profile.handle,
         true <-
           Signup.hosted_handle?(profile.handle) or
             Handle.resolve(profile.handle, Keyword.put(opts, :force_refresh, true)) == {:ok, did} do
      Repo.transaction(fn ->
        Events.lock!()

        head =
          Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
            Repo.rollback(:account_not_found)

        case expected_key(head, expected) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        current_profile = Repo.get(Profile, did)

        unless is_struct(current_profile, Profile) and current_profile.handle == profile.handle and
                 Repo.get(Observation, did) == observation,
               do: Repo.rollback(:stale_identity_refresh)

        if Repo.get_by(HandleReservation, did: did), do: Repo.rollback(:plc_update_pending)
        changed? = head.curve != key.curve or head.public_key != key.public
        if changed?, do: Events.append!(:identity, head, %{"handle" => profile.handle})

        updated =
          case Repositories.rotate_signing_key(did, key, head.head) do
            {:ok, updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end

        if changed? do
          fingerprint =
            :crypto.hash(
              :sha256,
              CBOR.encode!(%{
                "handle" => profile.handle,
                "claimedHandle" => identity.claimed_handle,
                "pds" => identity.pds,
                "curve" => Atom.to_string(key.curve),
                "key" => %CBOR.Bytes{data: key.public}
              })
            )

          Repo.insert!(%Observation{did: did, handle: profile.handle, fingerprint: fingerprint},
            on_conflict: {:replace, [:handle, :fingerprint]},
            conflict_target: [:did]
          )
        end

        result = if changed?, do: :rotated, else: :unchanged
        Atoll.Moderation.Audit.repository_key!(head, updated, expected, result)
        %{did: did, result: result, commit: Atoll.CID.to_base32(updated.head)}
      end)
    else
      true -> {:error, :rotation_inside_transaction}
      false -> {:error, :invalid_key_rotation}
      nil -> {:error, :account_not_found}
      {:error, _} = error -> error
      _ -> {:error, :invalid_key_rotation}
    end
  end

  def rotate(_, _, _, _), do: {:error, :invalid_key_rotation}

  defp expected_key(head, expected) do
    if Multikey.to_did_key(head.curve, head.public_key) == {:ok, expected},
      do: :ok,
      else: {:error, :stale_signing_key}
  end
end
