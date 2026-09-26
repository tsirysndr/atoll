defmodule Atoll.Repo.Migrations.CreatePlcUpdateJournal do
  use Ecto.Migration

  def change do
    create table(:plc_updates, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :cid, :text, primary_key: true
      add :previous, :map, null: false
      add :operation, :map, null: false
      add :confirmed_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plc_updates, [:did],
             where: "completed_at IS NULL",
             name: :plc_updates_one_pending
           )

    create constraint(:plc_updates, :plc_update_completion_requires_confirmation,
             check: "completed_at IS NULL OR confirmed_at IS NOT NULL"
           )
  end
end
