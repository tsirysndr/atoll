defmodule Atoll.Identity.PLC.PendingAuthorityKeys do
  @moduledoc """
  Internal encrypted custody of replacement PLC authority keys bound to immutable PLC updates.

  This is not an authorization boundary. The caller must authorize the operation,
  obtain fresh directory evidence, and atomically stage any local reservations.
  Staging never submits to the directory or changes the active PLC authority key.
  """
  import Ecto.Query
  alias Atoll.{CBOR, MasterKeys, Multikey, Repo, SigningKey}
  alias Atoll.Repositories.{Events, Head}
  alias Atoll.Identity.PLC.{Operation, Recoveries, Registrations, RotationKeys, Update, Updates}

  def stage(did, audit, operation, expected, key),
    do: stage_key(did, audit, operation, expected, key, :ordinary)

  @doc "Stage supplied authority custody for a recovery, without decrypting the old envelope."
  def stage_recovery(did, audit, operation, expected, key, now \\ DateTime.utc_now()),
    do: stage_key(did, audit, operation, expected, key, {:recovery, now})

  defp stage_key(did, audit, operation, expected, %SigningKey{} = key, mode)
       when is_map(operation) do
    with {:ok, master} <- MasterKeys.active(),
         {:ok, _} <- Multikey.from_did_key(expected),
         {:ok, derived} <- SigningKey.from_private(key.curve, key.private),
         true <- derived.public == key.public,
         {:ok, public} <- Multikey.to_did_key(key.curve, key.public),
         true <- mode != :ordinary or public != expected,
         true <- public in Operation.rotation_keys(operation),
         {:ok, cid} <- Operation.cid(operation) do
      Repo.transaction(fn ->
        head = lock!(did)
        unless head.status in [:active, :deactivated], do: Repo.rollback(:repo_inactive)

        current_public =
          if mode == :ordinary do
            with {:ok, current} <- Registrations.rotation_key(did),
                 do: Multikey.to_did_key(current.curve, current.public)
          else
            RotationKeys.public_key(did)
          end

        case current_public do
          {:ok, ^expected} -> :ok
          {:ok, _} -> Repo.rollback(:stale_rotation_key)
          {:error, reason} -> Repo.rollback(reason)
        end

        journal =
          case mode do
            :ordinary -> Updates.stage(did, audit, operation)
            {:recovery, now} -> Recoveries.stage(did, audit, operation, now)
          end

        case journal do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        row = Repo.get_by!(Update, did: did, cid: cid)

        unless permitted_key?(row, expected, public), do: Repo.rollback(:invalid_rotation_key)
        if row.signing_public_key, do: Repo.rollback(:pending_key_conflict)

        cond do
          row.completed_at ->
            Repo.rollback(:plc_update_completed)

          row.authority_envelope ->
            unless row.expected_authority_key == expected and fetch(did, cid) == {:ok, key},
              do: Repo.rollback(:pending_key_conflict)

            :unchanged

          row.authority_public_key ->
            Repo.rollback(:pending_key_conflict)

          Repo.exists?(
            from u in Update, where: u.did == ^did and not is_nil(u.authority_envelope)
          ) ->
            Repo.rollback(:pending_key_conflict)

          true ->
            bound = %{
              row
              | authority_curve: key.curve,
                authority_public_key: key.public,
                expected_authority_key: expected
            }

            row
            |> Ecto.Changeset.change(
              authority_curve: key.curve,
              authority_public_key: key.public,
              expected_authority_key: expected,
              authority_envelope: encrypt(bound, key.private, master)
            )
            |> Repo.update!(log: false)

            :stored
        end
      end)
    else
      false -> {:error, :invalid_key}
      error -> error
    end
  end

  defp stage_key(_, _, _, _, _, _), do: {:error, :invalid_key}

  def fetch(did, cid) do
    with {:ok, master} <- MasterKeys.active() do
      case Repo.get_by(Update, [did: did, cid: cid], log: false) do
        %Update{authority_envelope: envelope} = row when is_binary(envelope) ->
          MasterKeys.decrypt(master, &decrypt(row, &1))

        _ ->
          {:error, :key_not_found}
      end
    end
  end

  @doc "Erase pending custody only in the transaction that completes a matching local rotation."
  def release!(did, cid) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "pending-key release requires a transaction")

    lock!(did)
    row = Repo.get_by(Update, did: did, cid: cid) || Repo.rollback(:plc_update_not_found)
    unless row.completed_at, do: Repo.rollback(:pending_key_not_completed)

    case Registrations.rotation_key(did) do
      {:ok, key}
      when key.curve == row.authority_curve and key.public == row.authority_public_key ->
        :ok

      _ ->
        Repo.rollback(:pending_key_not_completed)
    end

    row |> Ecto.Changeset.change(authority_envelope: nil) |> Repo.update!(log: false)
    :ok
  end

  @doc false
  def rewrap!(did, master) do
    case Repo.one(
           from(u in Update,
             where: u.did == ^did and not is_nil(u.authority_envelope),
             lock: "FOR UPDATE"
           ),
           log: false
         ) do
      nil ->
        :absent

      row ->
        case decrypt(row, master) do
          {:ok, _} ->
            :unchanged

          _ ->
            case MasterKeys.decrypt(master, &decrypt(row, &1)) do
              {:ok, key} ->
                row
                |> Ecto.Changeset.change(authority_envelope: encrypt(row, key.private, master))
                |> Repo.update!(log: false)

                :rotated

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
    end
  end

  defp permitted_key?(%{recovery_expected_head: head} = row, _, public) when is_binary(head) do
    public in Operation.rotation_keys(row.operation) and
      match?({:ok, _}, Operation.verify_update(row.previous, row.operation))
  end

  defp permitted_key?(row, expected, public) do
    with {:ok, successor} <- Operation.successor(row.previous),
         true <- expected in successor["rotationKeys"],
         false <- public in successor["rotationKeys"],
         {:ok, _} <- Operation.verify_update(row.previous, row.operation) do
      keys =
        Enum.map(successor["rotationKeys"], fn key ->
          if key == expected, do: public, else: key
        end)

      Map.delete(row.operation, "sig") == Map.put(successor, "rotationKeys", keys)
    else
      _ -> false
    end
  end

  defp lock!(did) do
    Events.lock!()

    Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
      Repo.rollback(:account_not_found)
  end

  defp decrypt(
         %{
           authority_envelope:
             <<1, nonce::binary-size(12), ciphertext::binary-size(32), tag::binary-size(16)>>
         } = row,
         master
       ) do
    with {:ok, cid} <- Operation.cid(row.operation),
         true <- cid == row.cid,
         {:ok, public} <- Multikey.to_did_key(row.authority_curve, row.authority_public_key),
         true <- permitted_key?(row, row.expected_authority_key, public),
         private when is_binary(private) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             master,
             nonce,
             ciphertext,
             aad(row),
             tag,
             false
           ),
         {:ok, key} <- SigningKey.from_private(row.authority_curve, private),
         true <- key.public == row.authority_public_key do
      {:ok, key}
    else
      _ -> {:error, :key_decryption_failed}
    end
  end

  defp decrypt(_, _), do: {:error, :key_decryption_failed}

  defp encrypt(row, private, master) do
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, master, nonce, private, aad(row), 16, true)

    <<1, nonce::binary, ciphertext::binary, tag::binary>>
  end

  defp aad(row),
    do:
      CBOR.encode!([
        if(row.recovery_expected_head,
          do: "atoll.pending-plc-authority-recovery-key.v1",
          else: "atoll.pending-plc-authority-key.v1"
        ),
        row.did,
        row.cid,
        row.expected_authority_key,
        Atom.to_string(row.authority_curve),
        %CBOR.Bytes{data: row.authority_public_key}
      ])
end
