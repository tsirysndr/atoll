defmodule Atoll.Repo.Migrations.TrackRevisionAgeAndEventDependencies do
  use Ecto.Migration

  def up do
    alter table(:repository_revisions) do
      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('UTC', now())")
    end

    create index(:repository_revisions, [:did, :inserted_at, :rev])

    create table(:event_revision_dependencies, primary_key: false) do
      add :seq,
          references(:repository_events, column: :seq, type: :bigint, on_delete: :delete_all),
          primary_key: true

      add :head, :binary, primary_key: true
      add :did, :text, null: false
    end

    create index(:event_revision_dependencies, [:did, :head])
    execute "LOCK TABLE repository_events IN SHARE ROW EXCLUSIVE MODE"
    flush()
    backfill(0)
  end

  defp backfill(cursor) do
    rows =
      repo().query!(
        "SELECT seq, did, kind, payload FROM repository_events WHERE seq > $1 AND kind IN ('commit', 'sync') ORDER BY seq LIMIT 1000",
        [cursor]
      ).rows

    entries =
      Enum.flat_map(rows, fn [seq, did, kind, bytes] ->
        {:ok, payload} = Atoll.CBOR.decode(bytes)
        Atoll.Repositories.EventDependencies.rows(seq, did, kind, payload)
      end)

    if entries != [], do: repo().insert_all("event_revision_dependencies", entries)
    if rows != [], do: backfill(hd(List.last(rows)))
  end

  def down do
    drop table(:event_revision_dependencies)
    drop index(:repository_revisions, [:did, :inserted_at, :rev])
    alter table(:repository_revisions), do: remove(:inserted_at)
  end
end
