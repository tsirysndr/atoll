defmodule Atoll.Repo.Migrations.CreateHandleChangeReservations do
  use Ecto.Migration

  def change do
    create table(:handle_change_reservations, primary_key: false) do
      add :handle, :text, primary_key: true

      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        null: false

      add :cid, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:handle_change_reservations, [:did])

    execute "ALTER TABLE handle_change_reservations ADD CONSTRAINT handle_change_update_fk FOREIGN KEY (did, cid) REFERENCES plc_updates (did, cid) ON DELETE CASCADE",
            "ALTER TABLE handle_change_reservations DROP CONSTRAINT handle_change_update_fk"
  end
end
