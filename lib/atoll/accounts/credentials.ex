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
    if Syntax.did?(did) and valid_password?(password) do
      # Hash before acquiring database locks.
      hash = Argon2.hash_pwd_salt(password, argon2_type: 2)

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

  @doc "Verifies a password for a DID, returning no password hash or credential struct."
  def verify(did, password) do
    if Syntax.did?(did) and valid_password?(password) do
      valid? =
        case Repo.get(Credential, did) do
          nil -> Argon2.no_user_verify(argon2_type: 2)
          credential -> Argon2.verify_pass(password, credential.password_hash)
        end

      if valid?, do: {:ok, %{did: did}}, else: {:error, :invalid_credentials}
    else
      {:error, :invalid_credentials}
    end
  end

  defp valid_password?(value) when is_binary(value) and byte_size(value) in 8..1024,
    do: String.valid?(value)

  defp valid_password?(_), do: false
end
