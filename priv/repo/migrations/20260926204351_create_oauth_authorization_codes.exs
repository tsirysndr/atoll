defmodule Atoll.Repo.Migrations.CreateOauthAuthorizationCodes do
  use Ecto.Migration

  def change do
    create table(:oauth_authorization_codes, primary_key: false) do
      add :digest, :binary, primary_key: true

      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        null: false

      add :source_session_id,
          references(:account_sessions, column: :id, type: :string, on_delete: :delete_all),
          null: false

      add :issuer, :text, null: false
      add :client_id, :text, null: false
      add :redirect_uri, :text, null: false
      add :scope, :text, null: false
      add :code_challenge, :text, null: false
      add :dpop_jkt, :text, null: false
      add :client_binding, :map
      add :refresh_allowed, :boolean, null: false
      add :expires_at, :bigint, null: false
    end

    create index(:oauth_authorization_codes, [:expires_at, :digest])
    create index(:oauth_authorization_codes, [:did])
    create index(:oauth_authorization_codes, [:source_session_id])

    create constraint(:oauth_authorization_codes, :oauth_authorization_code_shape,
             check:
               "octet_length(digest) = 32 AND expires_at > 0 AND octet_length(dpop_jkt) = 43 AND octet_length(code_challenge) = 43"
           )
  end
end
