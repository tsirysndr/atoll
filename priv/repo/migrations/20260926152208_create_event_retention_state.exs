defmodule Atoll.Repo.Migrations.CreateEventRetentionState do
  use Ecto.Migration

  def change do
    create table(:event_retention_state, primary_key: false) do
      add :id, :integer, primary_key: true
      add :cursor_floor, :bigint, null: false, default: 0
    end

    create constraint(:event_retention_state, :singleton_event_retention,
             check: "id = 1 AND cursor_floor >= 0"
           )

    execute "INSERT INTO event_retention_state (id, cursor_floor) VALUES (1, 0)",
            "DELETE FROM event_retention_state WHERE id = 1"
  end
end
