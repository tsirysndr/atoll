defmodule Atoll.Repo.Migrations.CreateAppPasswords do
  use Ecto.Migration

  def change do
    create table(:app_passwords, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        null: false

      add :name, :text, null: false
      add :digest, :binary, null: false
      add :privileged, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:app_passwords, [:did, :name])
    create unique_index(:app_passwords, [:did, :digest])

    create constraint(:app_passwords, :app_password_digest_size,
             check: "octet_length(digest) = 32"
           )

    alter table(:account_sessions) do
      add :app_password_id, references(:app_passwords, type: :uuid, on_delete: :delete_all)
      add :access_scope, :text, null: false, default: "com.atproto.access"
    end

    create index(:account_sessions, [:app_password_id])

    create constraint(:account_sessions, :session_app_scope,
             check:
               "(app_password_id IS NULL AND access_scope = 'com.atproto.access') OR (app_password_id IS NOT NULL AND access_scope IN ('com.atproto.appPass', 'com.atproto.appPassPrivileged'))"
           )
  end
end
