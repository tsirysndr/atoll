defmodule Atoll.Repo.Migrations.IndexBlockCleanupReferences do
  use Ecto.Migration

  def change do
    alter table(:blocks) do
      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('UTC', now())")
    end

    create index(:blocks, [:inserted_at, :cid])
    create index(:repository_revisions, [:blocks], using: :gin)
  end
end
