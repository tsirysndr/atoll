defmodule Atoll.Repo.Migrations.CreateAccountSessions do
  use Ecto.Migration

  def change do
    create table(:account_sessions, primary_key: false) do
      add :id, :string, size: 43, primary_key: true

      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        null: false

      add :refresh_hash, :binary, null: false
      add :expires_at, :bigint, null: false
    end

    create index(:account_sessions, [:did])
    create index(:account_sessions, [:expires_at])

    create constraint(:account_sessions, :refresh_hash_length,
             check: "octet_length(refresh_hash) = 32"
           )

    create constraint(:account_sessions, :session_expiration, check: "expires_at > 0")
  end
end
