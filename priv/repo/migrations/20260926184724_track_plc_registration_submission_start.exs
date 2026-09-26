defmodule Atoll.Repo.Migrations.TrackPlcRegistrationSubmissionStart do
  use Ecto.Migration

  def up do
    alter table(:plc_registrations) do
      add :submission_started_at, :utc_datetime_usec
    end

    # Legacy rows cannot prove that no request escaped before this migration.
    execute "UPDATE plc_registrations SET submission_started_at = COALESCE(confirmed_at, timezone('UTC', now()))"

    create index(:plc_registrations, [:inserted_at, :did],
             name: :plc_registrations_cleanup_candidates,
             where:
               "submission_started_at IS NULL AND confirmed_at IS NULL AND completed_at IS NULL"
           )
  end

  def down do
    drop index(:plc_registrations, [:inserted_at, :did],
           name: :plc_registrations_cleanup_candidates
         )

    alter table(:plc_registrations) do
      remove :submission_started_at
    end
  end
end
