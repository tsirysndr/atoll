defmodule Atoll.Repo.Migrations.CreateOauthSessionsAndAccessTokens do
  use Ecto.Migration

  def change do
    create table(:oauth_sessions, primary_key: false) do
      add :id, :string, size: 43, primary_key: true

      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        null: false

      add :source_session_id,
          references(:account_sessions, column: :id, type: :string, on_delete: :delete_all),
          null: false

      add :issuer, :text, null: false
      add :client_id, :text, null: false
      add :scope, :text, null: false
      add :dpop_jkt, :text, null: false
      add :client_binding, :map
      add :refresh_digest, :binary
      add :expires_at, :bigint, null: false
    end

    create index(:oauth_sessions, [:did])
    create index(:oauth_sessions, [:source_session_id])
    create index(:oauth_sessions, [:expires_at, :id])
    create unique_index(:oauth_sessions, [:refresh_digest])

    create constraint(:oauth_sessions, :oauth_session_shape,
             check:
               "octet_length(id) = 43 AND octet_length(dpop_jkt) = 43 AND expires_at > 0 AND (refresh_digest IS NULL OR octet_length(refresh_digest) = 32)"
           )

    create table(:oauth_access_tokens, primary_key: false) do
      add :digest, :binary, primary_key: true

      add :session_id,
          references(:oauth_sessions, column: :id, type: :string, on_delete: :delete_all),
          null: false

      add :expires_at, :bigint, null: false
    end

    create index(:oauth_access_tokens, [:session_id])
    create index(:oauth_access_tokens, [:expires_at, :digest])

    create constraint(:oauth_access_tokens, :oauth_access_token_shape,
             check: "octet_length(digest) = 32 AND expires_at > 0"
           )

    alter table(:oauth_authorization_codes) do
      add :redeemed_at, :bigint

      add :redeemed_session_id,
          references(:oauth_sessions, column: :id, type: :string, on_delete: :nilify_all)

      add :replay_until, :bigint
    end

    create index(:oauth_authorization_codes, [:redeemed_session_id])
    create index(:oauth_authorization_codes, [:replay_until, :digest])

    create constraint(:oauth_authorization_codes, :oauth_code_redemption_shape,
             check:
               "(redeemed_at IS NULL AND redeemed_session_id IS NULL AND replay_until IS NULL) OR (redeemed_at IS NOT NULL AND redeemed_at > 0 AND replay_until IS NOT NULL AND replay_until >= redeemed_at)"
           )
  end
end
