defmodule Atoll.Repo.Migrations.CreateRepositoryKeys do
  use Ecto.Migration

  def change do
    create table(:repository_keys, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :envelope, :binary, null: false
    end

    create constraint(:repository_keys, :key_envelope_length,
             check: "octet_length(envelope) = 61"
           )
  end
end
