defmodule Atoll.Repo.Migrations.IndexRepositoryRecordsByCollection do
  use Ecto.Migration

  def change do
    execute(
      "CREATE INDEX repository_records_collection_did_index ON repository_records ((split_part(path, '/', 1)), (did COLLATE \"C\"))",
      "DROP INDEX repository_records_collection_did_index"
    )
  end
end
