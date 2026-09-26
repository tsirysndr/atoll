defmodule Atoll.Repo.Migrations.AddOauthRefreshRotation do
  use Ecto.Migration

  def up do
    create table(:oauth_refresh_uses, primary_key: false) do
      add :digest, :binary, primary_key: true

      add :session_id, references(:oauth_sessions, type: :string, on_delete: :delete_all),
        null: false

      add :expires_at, :bigint, null: false
    end

    create index(:oauth_refresh_uses, [:session_id])
    create index(:oauth_refresh_uses, [:expires_at, :digest])

    create constraint(:oauth_refresh_uses, :oauth_refresh_use_shape,
             check: "octet_length(digest) = 32 AND expires_at > 0"
           )

    alter table(:oauth_access_tokens) do
      add :scope, :text
    end

    execute "UPDATE oauth_access_tokens AS t SET scope = s.scope FROM oauth_sessions AS s WHERE t.session_id = s.id"

    alter table(:oauth_access_tokens) do
      modify :scope, :text, null: false
    end
  end

  def down do
    alter table(:oauth_access_tokens) do
      remove :scope
    end

    drop table(:oauth_refresh_uses)
  end
end
