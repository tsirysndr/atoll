defmodule Atoll.Repo.Migrations.CreateModerationAuditEntries do
  use Ecto.Migration

  def change do
    # Deliberately no account FK: account deletion must not erase operator history.
    create table(:moderation_audit_entries) do
      add :did, :text, null: false
      add :subject, :map, null: false
      add :actor, :text, null: false
      add :operation, :text, null: false
      add :requested, :map, null: false
      add :before_state, :map, null: false
      add :after_state, :map, null: false
      add :time, :utc_datetime_usec, null: false
    end

    create index(:moderation_audit_entries, [:did, :id])
  end
end
