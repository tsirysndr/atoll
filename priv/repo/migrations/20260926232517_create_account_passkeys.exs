defmodule Atoll.Repo.Migrations.CreateAccountPasskeys do
  use Ecto.Migration

  def change do
    create table(:account_passkey_users, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :user_handle, :binary, null: false
    end

    create unique_index(:account_passkey_users, [:user_handle])

    create constraint(:account_passkey_users, :passkey_user_shape,
             check: "octet_length(user_handle) = 32"
           )

    create table(:account_passkeys, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :did,
          references(:account_passkey_users, column: :did, type: :text, on_delete: :delete_all),
          null: false

      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :rp_id, :text, null: false
      add :name, :text, null: false
      add :sign_count, :bigint, null: false
      add :backup_eligible, :boolean, null: false
      add :backup_state, :boolean, null: false
      add :created_at, :bigint, null: false
      add :last_used_at, :bigint
    end

    create unique_index(:account_passkeys, [:credential_id])
    create index(:account_passkeys, [:did])

    create constraint(:account_passkeys, :passkey_shape,
             check:
               "octet_length(credential_id) BETWEEN 1 AND 1023 AND octet_length(public_key) = 65 AND octet_length(name) BETWEEN 1 AND 64 AND sign_count BETWEEN 0 AND 4294967295 AND (NOT backup_state OR backup_eligible) AND created_at > 0"
           )

    alter table(:account_sessions) do
      add :passkey_id, references(:account_passkeys, type: :uuid, on_delete: :delete_all)
    end

    create index(:account_sessions, [:passkey_id])

    create constraint(:account_sessions, :session_passkey_scope,
             check:
               "passkey_id IS NULL OR (app_password_id IS NULL AND access_scope = 'com.atproto.access')"
           )

    create table(:account_passkey_challenges, primary_key: false) do
      add :digest, :binary, primary_key: true
      add :browser_hash, :binary, null: false
      add :challenge, :binary, null: false
      add :kind, :text, null: false
      add :origin, :text, null: false
      add :rp_id, :text, null: false
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all)

      add :source_session_id,
          references(:account_sessions, column: :id, type: :string, on_delete: :delete_all)

      add :credential_digest, :binary
      add :totp_version, :text
      add :name, :text
      add :expires_at, :bigint, null: false
    end

    create index(:account_passkey_challenges, [:expires_at, :digest])
    create index(:account_passkey_challenges, [:source_session_id])

    create constraint(:account_passkey_challenges, :passkey_challenge_shape,
             check:
               "octet_length(digest) = 32 AND octet_length(browser_hash) = 32 AND octet_length(challenge) = 32 AND expires_at > 0 AND ((kind = 'register' AND did IS NOT NULL AND source_session_id IS NOT NULL AND credential_digest IS NOT NULL AND octet_length(credential_digest) = 32 AND name IS NOT NULL) OR (kind = 'login' AND did IS NULL AND source_session_id IS NULL AND credential_digest IS NULL AND totp_version IS NULL AND name IS NULL))"
           )
  end
end
