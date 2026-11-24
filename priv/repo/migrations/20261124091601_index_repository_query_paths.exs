defmodule Atoll.Repo.Migrations.IndexRepositoryQueryPaths do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Match bytewise path pagination and avoid a sort/heap fetch on every write.
    create index(:repository_records, [:did, "path COLLATE \"C\""],
             name: :repository_records_did_path_c_index,
             include: [:cid],
             concurrently: true
           )

    # Referencing-side indexes are also required for bounded block deletion:
    # PostgreSQL does not create these automatically for foreign keys.
    create index(:repository_records, [:cid], concurrently: true)
    create index(:repositories, [:head], concurrently: true)
    create index(:repository_revisions, [:head], concurrently: true)
  end
end
