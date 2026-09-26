defmodule Atoll.Repo.Migrations.RecordNullifiedPlcUpdates do
  use Ecto.Migration

  def up do
    alter table(:plc_updates) do
      add :nullified_at, :utc_datetime_usec
      add :nullified_head, :text
    end

    create constraint(:plc_updates, :nullified_update_shape,
             check:
               "(nullified_at IS NULL AND nullified_head IS NULL) OR " <>
                 "(nullified_at IS NOT NULL AND nullified_head IS NOT NULL AND completed_at IS NULL AND signing_envelope IS NULL AND authority_envelope IS NULL)"
           )

    drop index(:plc_updates, [:did], name: :plc_updates_one_pending)

    create unique_index(:plc_updates, [:did],
             name: :plc_updates_one_pending,
             where: "completed_at IS NULL AND nullified_at IS NULL"
           )
  end

  def down do
    # Never silently reopen operations that were explicitly closed as nullified.
    create constraint(:plc_updates, :no_nullified_updates, check: "nullified_at IS NULL")
    drop index(:plc_updates, [:did], name: :plc_updates_one_pending)

    create unique_index(:plc_updates, [:did],
             name: :plc_updates_one_pending,
             where: "completed_at IS NULL"
           )

    drop constraint(:plc_updates, :no_nullified_updates)
    drop constraint(:plc_updates, :nullified_update_shape)

    alter table(:plc_updates) do
      remove :nullified_at
      remove :nullified_head
    end
  end
end
