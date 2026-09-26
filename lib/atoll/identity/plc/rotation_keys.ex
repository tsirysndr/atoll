defmodule Atoll.Identity.PLC.RotationKeys do
  @moduledoc "Operator-installed PLC rotation keys verified against fresh directory authority; not an HTTP authorization boundary."
  import Ecto.Query
  alias Atoll.{CBOR, MasterKeys, Multikey, Repo, SigningKey}
  alias Atoll.Identity.PLC.{Client, Operation, RotationKey, Update}
  alias Atoll.Repositories.{Events, Head}

  def install(did, key, opts \\ []), do: store(did, key, :absent, opts)

  @doc "Replace an installed key only when its public key matches the operator's expected did:key."
  def replace(did, expected, key, opts \\ []) do
    case Multikey.from_did_key(expected) do
      {:ok, _} -> store(did, key, expected, opts)
      _ -> {:error, :invalid_rotation_key}
    end
  end

  defp store(did, %SigningKey{} = key, expected, opts) do
    with false <- Repo.in_transaction?(),
         {:ok, derived} <- SigningKey.from_private(key.curve, key.private),
         true <- derived.public == key.public,
         {:ok, id} <- Multikey.to_did_key(key.curve, key.public),
         {:ok, master} <- MasterKeys.active(),
         {:ok, %{state: state}} <- Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         true <- not state.tombstoned and id in Operation.rotation_keys(state.operation) do
      Repo.transaction(fn ->
        Events.lock!()

        Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
          Repo.rollback(:account_not_found)

        if Repo.exists?(from u in Update, where: u.did == ^did and is_nil(u.completed_at)),
          do: Repo.rollback(:plc_update_pending)

        before_key = Repo.get(RotationKey, did, log: false)

        result =
          case before_key do
            nil ->
              if expected != :absent, do: Repo.rollback(:key_not_found)

              row = %RotationKey{
                did: did,
                curve: key.curve,
                public_key: key.public,
                verified_cid: state.cid
              }

              Repo.insert!(%{row | envelope: encrypt(row, key.private, master)}, log: false)
              :installed

            row when expected != :absent ->
              {:ok, current} = Multikey.to_did_key(row.curve, row.public_key)
              unless current == expected, do: Repo.rollback(:stale_rotation_key)
              updated = %{row | curve: key.curve, public_key: key.public, verified_cid: state.cid}

              row
              |> Ecto.Changeset.change(
                curve: key.curve,
                public_key: key.public,
                verified_cid: state.cid,
                envelope: encrypt(updated, key.private, master)
              )
              |> Repo.update!(log: false)

              :replaced

            %{curve: curve, public_key: public} = row
            when curve == key.curve and public == key.public ->
              case decrypt(row, master) do
                {:ok, _} -> :unchanged
                {:error, reason} -> Repo.rollback(reason)
              end

            _ ->
              Repo.rollback(:rotation_key_exists)
          end

        Atoll.Moderation.Audit.rotation_key!(
          did,
          expected,
          state.cid,
          before_key,
          Repo.get!(RotationKey, did, log: false),
          result
        )

        result
      end)
    else
      true -> {:error, :plc_update_inside_transaction}
      false -> {:error, :invalid_rotation_key}
      error -> error
    end
  end

  defp store(_, _, _, _), do: {:error, :invalid_rotation_key}

  @doc "Internal atomic adoption after the caller freshly verifies the staged update is current."
  def adopt_pending!(did, cid) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "authority-key adoption requires a transaction")

    Events.lock!()

    head =
      Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
        Repo.rollback(:account_not_found)

    unless head.status in [:active, :deactivated], do: Repo.rollback(:repo_inactive)
    row = Repo.get_by(Update, did: did, cid: cid) || Repo.rollback(:plc_update_not_found)
    unless row.confirmed_at, do: Repo.rollback(:plc_update_unconfirmed)

    with {:ok, master} <- MasterKeys.active(),
         {:ok, key} <- Atoll.Identity.PLC.PendingAuthorityKeys.fetch(did, cid),
         {:ok, old} <- Atoll.Identity.PLC.Registrations.rotation_key(did),
         {:ok, current} <- Multikey.to_did_key(old.curve, old.public),
         {:ok, replacement} <- Multikey.to_did_key(key.curve, key.public) do
      unless current in [row.expected_authority_key, replacement],
        do: Repo.rollback(:stale_rotation_key)

      updated = %RotationKey{
        did: did,
        curve: key.curve,
        public_key: key.public,
        verified_cid: cid
      }

      envelope = encrypt(updated, key.private, master)

      case Repo.get(RotationKey, did, log: false) do
        nil ->
          Repo.insert!(%{updated | envelope: envelope}, log: false)

        stored ->
          stored
          |> Ecto.Changeset.change(
            curve: key.curve,
            public_key: key.public,
            verified_cid: cid,
            envelope: envelope
          )
          |> Repo.update!(log: false)
      end

      :ok
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def fetch(did) do
    with {:ok, master} <- MasterKeys.active() do
      case Repo.get(RotationKey, did, log: false) do
        nil -> {:error, :key_not_found}
        row -> decrypt(row, master)
      end
    end
  end

  @doc false
  def rewrap!(did, master) do
    case Repo.one(from(r in RotationKey, where: r.did == ^did, lock: "FOR UPDATE"), log: false) do
      nil ->
        :absent

      row ->
        case decrypt_one(row, master) do
          {:ok, _} ->
            :unchanged

          _ ->
            case decrypt(row, master) do
              {:ok, key} ->
                row
                |> Ecto.Changeset.change(envelope: encrypt(row, key.private, master))
                |> Repo.update!(log: false)

                :rotated

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
    end
  end

  defp decrypt(row, master), do: MasterKeys.decrypt(master, &decrypt_one(row, &1))

  defp decrypt_one(
         %{
           envelope:
             <<1, nonce::binary-size(12), ciphertext::binary-size(32), tag::binary-size(16)>>
         } = row,
         master
       ) do
    with private when is_binary(private) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             master,
             nonce,
             ciphertext,
             aad(row),
             tag,
             false
           ),
         {:ok, key} <- SigningKey.from_private(row.curve, private),
         true <- key.public == row.public_key do
      {:ok, key}
    else
      _ -> {:error, :key_decryption_failed}
    end
  end

  defp decrypt_one(_, _), do: {:error, :key_decryption_failed}

  defp encrypt(row, private, master) do
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, master, nonce, private, aad(row), 16, true)

    <<1, nonce::binary, ciphertext::binary, tag::binary>>
  end

  defp aad(row),
    do:
      CBOR.encode!([
        "atoll.imported-plc-key.v1",
        row.did,
        Atom.to_string(row.curve),
        %CBOR.Bytes{data: row.public_key},
        row.verified_cid
      ])
end
