defmodule Atoll.Repo.Migrations.CreateRepositoryRevisions do
  use Ecto.Migration

  def change do
    create table(:repository_revisions, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :rev, :string, size: 13, primary_key: true
      add :head, references(:blocks, column: :cid, type: :binary), null: false
      add :blocks, {:array, :binary}, null: false
    end
  end
end
