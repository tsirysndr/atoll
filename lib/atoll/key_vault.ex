defmodule Atoll.KeyVault do
  @moduledoc """
  Internal encrypted signing-key storage. Not an authorization boundary.

  AES-256-GCM envelopes bind the DID, curve and public key as authenticated data.
  The 32-byte master key comes from runtime configuration and is never stored in
  PostgreSQL. Keys are insert-only; key rotation requires a separate workflow.
  """
  import Ecto.Query
  alias Atoll.{CBOR, Repo, SigningKey}
  alias Atoll.CBOR.Bytes
  alias Atoll.Repositories.{EncryptedKey, Head}

  def store(did, %SigningKey{} = key) when is_binary(did) do
    with {:ok, master} <- master_key(),
         {:ok, derived} <- SigningKey.from_private(key.curve, key.private),
         true <- derived.public == key.public do
      Repo.transaction(fn ->
        head = Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE")
        if is_nil(head), do: Repo.rollback(:not_found)

        if head.curve != key.curve or head.public_key != key.public,
          do: Repo.rollback(:invalid_key)

        nonce = :crypto.strong_rand_bytes(12)

        {ciphertext, tag} =
          :crypto.crypto_one_time_aead(
            :aes_256_gcm,
            master,
            nonce,
            key.private,
            aad(head),
            16,
            true
          )

        envelope = <<1, nonce::binary, ciphertext::binary, tag::binary>>

        case Repo.insert_all(EncryptedKey, [%{did: did, envelope: envelope}],
               on_conflict: :nothing,
               conflict_target: [:did],
               log: false
             ) do
          {1, _} -> :stored
          {0, _} -> Repo.rollback(:key_exists)
        end
      end)
    else
      false -> {:error, :invalid_key}
      error -> error
    end
  end

  def store(_, _), do: {:error, :invalid_key}

  def fetch(did) when is_binary(did) do
    with {:ok, master} <- master_key() do
      query =
        from k in EncryptedKey,
          join: h in Head,
          on: h.did == k.did,
          where: k.did == ^did,
          select: {h, k.envelope}

      case Repo.one(query, log: false) do
        nil -> {:error, :key_not_found}
        {head, envelope} -> decrypt(head, envelope, master)
      end
    end
  end

  defp decrypt(
         head,
         <<1, nonce::binary-size(12), ciphertext::binary-size(32), tag::binary-size(16)>>,
         master
       ) do
    with private when is_binary(private) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             master,
             nonce,
             ciphertext,
             aad(head),
             tag,
             false
           ),
         {:ok, key} <- SigningKey.from_private(head.curve, private),
         true <- key.public == head.public_key do
      {:ok, key}
    else
      _ -> {:error, :key_decryption_failed}
    end
  end

  defp decrypt(_, _, _), do: {:error, :key_decryption_failed}

  defp aad(head),
    do:
      CBOR.encode!([
        "atoll.repository-key.v1",
        head.did,
        Atom.to_string(head.curve),
        %Bytes{data: head.public_key}
      ])

  defp master_key do
    case Application.get_env(:atoll, :key_encryption_key) do
      <<_::binary-size(32)>> = key -> {:ok, key}
      _ -> {:error, :key_vault_unconfigured}
    end
  end
end
