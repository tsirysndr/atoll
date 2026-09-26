defmodule Atoll.Repo.Migrations.AllowServerWideAuditEntries do
  use Ecto.Migration

  def up do
    alter table(:moderation_audit_entries) do
      modify :did, :text, null: true
    end
  end

  # Intentionally fails if server-wide history exists, rather than deleting history.
  def down do
    alter table(:moderation_audit_entries) do
      modify :did, :text, null: false
    end
  end
end
