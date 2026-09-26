defmodule Atoll.Accounts.TOTPSecret do
  @moduledoc """
  Account-bound AES-256-GCM envelopes for 160-bit authenticator secrets.
  Internal cryptographic storage primitive, not an enrollment or authorization API.
  Uses the active master key and the existing bounded decryption-only fallback ring.
  """
  alias Atoll.{CBOR, MasterKeys, Syntax}

  def seal(did, <<_::160>> = secret) do
    with true <- Syntax.did?(did),
         {:ok, master} <- MasterKeys.active() do
      nonce = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, master, nonce, secret, aad(did), 16, true)

      {:ok, <<1, nonce::binary, ciphertext::binary, tag::binary>>}
    else
      false -> {:error, :invalid_totp_secret}
      error -> error
    end
  end

  def seal(_, _), do: {:error, :invalid_totp_secret}

  def open(did, <<1, _::binary-size(48)>> = envelope) do
    with true <- Syntax.did?(did),
         {:ok, master} <- MasterKeys.active(),
         {:ok, secret} <- MasterKeys.decrypt(master, &decrypt(did, envelope, &1)) do
      {:ok, secret}
    else
      false -> {:error, :invalid_totp_secret}
      error -> error
    end
  end

  def open(_, _), do: {:error, :invalid_totp_secret}

  @doc "Return an envelope under the active key; callers must persist it atomically before retiring fallback keys."
  def rewrap(did, envelope) do
    with {:ok, secret} <- open(did, envelope), do: seal(did, secret)
  end

  defp decrypt(
         did,
         <<1, nonce::binary-size(12), ciphertext::binary-size(20), tag::binary-size(16)>>,
         master
       ) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           master,
           nonce,
           ciphertext,
           aad(did),
           tag,
           false
         ) do
      <<_::160>> = secret -> {:ok, secret}
      _ -> {:error, :key_decryption_failed}
    end
  end

  defp aad(did), do: CBOR.encode!(["atoll.account-totp-secret.v1", did])
end
