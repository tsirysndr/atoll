defmodule Atoll.Repo.Migrations.CreateBlobReferences do
  use Ecto.Migration

  def change do
    create table(:blob_references, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :path, :text, primary_key: true
      add :cid, :binary, primary_key: true
      add :mime_type, :text, null: false
      add :size, :bigint, null: false
      add :rev, :string, size: 13, null: false
    end

    create index(:blob_references, [:did, :cid])
    create constraint(:blob_references, :reference_size, check: "size >= 0")
  end
end
