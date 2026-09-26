defmodule Atoll.Repo.Migrations.CreateRepositoryCredentials do
  use Ecto.Migration

  def change do
    create table(:repository_credentials, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :password_hash, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:repository_credentials, :password_hash_format,
             check: "password_hash LIKE '$argon2id$%' AND octet_length(password_hash) <= 512"
           )
  end
end
