defmodule Atoll.Repo.Migrations.MarkAdminDirectoryKeyUpdates do
  use Ecto.Migration

  def change do
    alter table(:plc_updates) do
      add :directory_key_update, :boolean, null: false, default: false
    end
  end
end
