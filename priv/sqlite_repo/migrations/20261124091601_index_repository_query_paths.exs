defmodule Atoll.Repo.Migrations.IndexRepositoryQueryPaths do
  use Ecto.Migration

  def change do
    # Match bytewise path pagination and avoid a sort/heap fetch on every write.
    create index(:repository_records, [:did, "path COLLATE BINARY"],
             name: :repository_records_did_path_c_index,
             unique: false
           )

    # Referencing-side indexes are also required for bounded block deletion:
    # PostgreSQL does not create these automatically for foreign keys.
    create index(:repository_records, [:cid])
    create index(:repositories, [:head])
    create index(:repository_revisions, [:head])
  end
end
