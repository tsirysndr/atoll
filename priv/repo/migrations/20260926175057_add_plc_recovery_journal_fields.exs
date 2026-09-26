defmodule Atoll.Repo.Migrations.AddPlcRecoveryJournalFields do
  use Ecto.Migration

  def change do
    alter table(:plc_updates) do
      add :recovery_expected_head, :text
      add :recovery_deadline, :utc_datetime_usec
      add :recovery_nullified_cids, {:array, :text}
    end

    create constraint(:plc_updates, :recovery_journal_shape,
             check:
               "(recovery_expected_head IS NULL AND recovery_deadline IS NULL AND recovery_nullified_cids IS NULL) OR (recovery_expected_head IS NOT NULL AND recovery_deadline IS NOT NULL AND recovery_nullified_cids IS NOT NULL AND cardinality(recovery_nullified_cids) BETWEEN 1 AND 999)"
           )
  end
end
