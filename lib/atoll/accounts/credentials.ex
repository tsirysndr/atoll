defmodule Atoll.Accounts.Credentials do
  @moduledoc """
  Internal password credentials for already-provisioned repositories.

  Creation is a trusted administrative operation, not public signup. Verification
  proves password possession only: it does not authorize repository operations,
  check repository status, or issue sessions. Callers must enforce those policies.
  Passwords are UTF-8, 8–1024 bytes, and are never trimmed or normalized.
  """
  import Ecto.Query
  alias Atoll.{Repo, Syntax}
  alias Atoll.Accounts.Credential
  alias Atoll.Repositories.Head

  @doc "Creates a salted Argon2id credential; never overwrites an existing credential."
  def create(did, password) do
    with true <- Syntax.did?(did),
         {:ok, hash} <- hash(password) do
      store_hash(did, hash)
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  @doc "Hashes a validated password before the caller acquires provisioning locks."
  def hash(password) do
    if valid_password?(password),
      do: {:ok, Argon2.hash_pwd_salt(password, argon2_type: 2)},
      else: {:error, :invalid_credentials}
  end

  @doc "Stores a trusted, precomputed Argon2id hash for a provisioned repository. Not an authentication API."
  def store_hash(did, "$argon2id$" <> _ = hash) when byte_size(hash) <= 512 do
    if Syntax.did?(did) do
      Repo.transaction(fn ->
        unless Repo.one(from h in Head, where: h.did == ^did, lock: "FOR SHARE"),
          do: Repo.rollback(:not_found)

        case Repo.insert_all(
               Credential,
               [%{did: did, password_hash: hash, inserted_at: DateTime.utc_now()}],
               on_conflict: :nothing,
               conflict_target: [:did],
               log: false
             ) do
          {1, _} -> %{did: did}
          {0, _} -> Repo.rollback(:credential_exists)
        end
      end)
    else
      {:error, :invalid_credentials}
    end
  end

  def store_hash(_, _), do: {:error, :invalid_credentials}

  @doc "Verifies a password for a DID, returning no password hash or credential struct."
  def verify(did, password) do
    case verified_digest(did, password) do
      {:ok, _} -> {:ok, %{did: did}}
      error -> error
    end
  end

  @doc false
  def verified_digest(did, password) do
    if Syntax.did?(did) and valid_password?(password) do
      case Repo.get(Credential, did) do
        nil ->
          Argon2.no_user_verify(argon2_type: 2)
          {:error, :invalid_credentials}

        credential ->
          if Argon2.verify_pass(password, credential.password_hash),
            do: {:ok, :crypto.hash(:sha256, credential.password_hash)},
            else: {:error, :invalid_credentials}
      end
    else
      {:error, :invalid_credentials}
    end
  end

  @doc false
  def current_digest?(did, expected) do
    case Repo.get(Credential, did) do
      nil ->
        false

      credential ->
        Plug.Crypto.secure_compare(:crypto.hash(:sha256, credential.password_hash), expected)
    end
  end

  defp valid_password?(value) when is_binary(value) and byte_size(value) in 8..1024,
    do: String.valid?(value)

  defp valid_password?(_), do: false
end
