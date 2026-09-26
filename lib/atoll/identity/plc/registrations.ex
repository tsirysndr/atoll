defmodule Atoll.Identity.PLC.Registrations do
  @moduledoc """
  Internal durable genesis registration journal, not an authorization boundary.

  Stage within the account provisioning transaction, after creating a deactivated
  repository, profile, and encrypted repository key. Submit only after committing.
  The signed operation and public key are insert-only. Private custody can be
  explicitly retired after completed key reconciliation. Directory confirmation
  is historical evidence of acceptance, not authorization to activate an account.
  """
  import Ecto.Query
  alias Atoll.{CBOR, KeyVault, Multikey, Repo, SigningKey}
  alias Atoll.CBOR.Bytes
  alias Atoll.Accounts.Profile
  alias Atoll.Repositories.{Events, Head}
  alias Atoll.Identity.PLC.{Client, Operation, Registration}

  def stage(did, operation, %SigningKey{} = rotation) do
    with :ok <- Operation.verify_genesis(did, operation),
         {:ok, cid} <- Operation.cid(operation),
         {:ok, derived} <- SigningKey.from_private(rotation.curve, rotation.private),
         true <- derived.public == rotation.public,
         {:ok, key_id} <- Multikey.to_did_key(rotation.curve, rotation.public),
         true <- key_id in Map.get(operation, "rotationKeys", []),
         {:ok, master} <- master_key() do
      Repo.transaction(fn ->
        Events.lock!()
        head = Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE")
        profile = Repo.get(Profile, did)

        unless head && head.status == :deactivated && profile,
          do: Repo.rollback(:invalid_registration_account)

        {:ok, repo_key_id} = Multikey.to_did_key(head.curve, head.public_key)

        unless operation["verificationMethods"]["atproto"] == repo_key_id and
                 operation["alsoKnownAs"] == ["at://" <> profile.handle],
               do: Repo.rollback(:invalid_registration_account)

        case KeyVault.fetch(did) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        case Repo.get(Registration, did, log: false) do
          nil ->
            row = %Registration{
              did: did,
              operation: operation,
              cid: cid,
              rotation_curve: rotation.curve,
              rotation_public_key: rotation.public
            }

            envelope = encrypt(row, rotation.private, master)
            Repo.insert!(%{row | rotation_envelope: envelope}, log: false)
            %{did: did, cid: cid}

          %{cid: ^cid, rotation_curve: curve, rotation_public_key: public} = existing
          when curve == rotation.curve and public == rotation.public ->
            case decrypt(existing, master) do
              {:ok, _} -> %{did: did, cid: cid}
              {:error, reason} -> Repo.rollback(reason)
            end

          _ ->
            Repo.rollback(:registration_exists)
        end
      end)
    else
      false -> {:error, :invalid_rotation_key}
      error -> error
    end
  end

  def stage(_, _, _), do: {:error, :invalid_rotation_key}

  @doc "Submits the stored operation without holding a transaction; safe to repeat after ambiguous failures."
  def submit(did, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :registration_inside_transaction}
    else
      case Repo.get(Registration, did, log: false) do
        nil ->
          {:error, :registration_not_found}

        row ->
          with {:ok, cid} <- Operation.cid(row.operation),
               true <- cid == row.cid,
               {:ok, _} <- KeyVault.fetch(did),
               {:ok, master} <- master_key(),
               {:ok, _} <- decrypt(row, master),
               {:ok, _} <- begin_submission(row),
               :ok <- Client.submit_genesis(did, row.operation, opts) do
            confirm(row)
          else
            false -> {:error, :invalid_plc_operation}
            error -> error
          end
      end
    end
  end

  defp begin_submission(row) do
    # Commit before network I/O. Cleanup takes the same locks, so either it wins
    # before this fence (and no POST follows), or the reservation is protected.
    Repo.transaction(fn ->
      Events.lock!()

      unless Repo.one(from h in Head, where: h.did == ^row.did, lock: "FOR UPDATE"),
        do: Repo.rollback(:registration_not_found)

      current = Repo.get(Registration, row.did, log: false)

      unless current && current.cid == row.cid && current.operation == row.operation,
        do: Repo.rollback(:registration_not_found)

      unless current.submission_started_at do
        current
        |> Ecto.Changeset.change(submission_started_at: DateTime.utc_now())
        |> Repo.update!(log: false)
      end

      :ok
    end)
  end

  @doc "Loads the retained PLC rotation key for internal identity operations."
  def rotation_key(did) do
    case Atoll.Identity.PLC.RotationKeys.fetch(did) do
      {:error, :key_not_found} -> registration_rotation_key(did)
      result -> result
    end
  end

  defp registration_rotation_key(did) do
    with {:ok, master} <- master_key() do
      case Repo.get(Registration, did, log: false) do
        nil -> {:error, :registration_not_found}
        row -> decrypt(row, master)
      end
    end
  end

  defp confirm(row) do
    # Do not overwrite the first acceptance time on retry. No account status changes.
    Repo.transaction(fn ->
      Events.lock!()

      unless Repo.one(from h in Head, where: h.did == ^row.did, lock: "FOR SHARE"),
        do: Repo.rollback(:registration_not_found)

      current = Repo.get(Registration, row.did, log: false)

      unless current && current.cid == row.cid,
        do: Repo.rollback(:registration_not_found)

      if is_nil(current.confirmed_at) do
        current
        |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now())
        |> Repo.update!(log: false)
      end

      %{did: row.did, cid: row.cid}
    end)
  end

  defp encrypt(row, private, master) do
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, master, nonce, private, aad(row), 16, true)

    <<1, nonce::binary, ciphertext::binary, tag::binary>>
  end

  defp decrypt_one(
         %{
           rotation_envelope:
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
         {:ok, key} <- SigningKey.from_private(row.rotation_curve, private),
         true <- key.public == row.rotation_public_key do
      {:ok, key}
    else
      _ -> {:error, :key_decryption_failed}
    end
  end

  defp decrypt_one(_, _), do: {:error, :key_decryption_failed}

  defp aad(row),
    do:
      CBOR.encode!([
        "atoll.plc-rotation-key.v1",
        row.did,
        row.cid,
        Atom.to_string(row.rotation_curve),
        %Bytes{data: row.rotation_public_key}
      ])

  defp master_key, do: Atoll.MasterKeys.active()
  defp decrypt(row, master), do: Atoll.MasterKeys.decrypt(master, &decrypt_one(row, &1))

  @doc false
  def rewrap!(did, master) do
    case Repo.one(from(r in Registration, where: r.did == ^did, lock: "FOR UPDATE"), log: false) do
      nil ->
        :absent

      %{rotation_retired_at: retired} when not is_nil(retired) ->
        :absent

      row ->
        case decrypt_one(row, master) do
          {:ok, _} ->
            :unchanged

          _ ->
            case decrypt(row, master) do
              {:ok, key} ->
                row
                |> Ecto.Changeset.change(rotation_envelope: encrypt(row, key.private, master))
                |> Repo.update!(log: false)

                :rotated

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
    end
  end
end
