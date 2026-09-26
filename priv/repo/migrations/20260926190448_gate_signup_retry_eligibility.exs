defmodule Atoll.Repo.Migrations.GateSignupRetryEligibility do
  use Ecto.Migration

  def change do
    alter table(:plc_registrations) do
      add :retry_eligible, :boolean, null: false, default: false
    end

    # Legacy submission markers include unknown history; only confirmation proves an attempt.
    execute "UPDATE plc_registrations SET retry_eligible = true WHERE confirmed_at IS NOT NULL AND submission_started_at IS NOT NULL",
            "SELECT 1"

    create constraint(:plc_registrations, :signup_retry_requires_submission,
             check: "NOT retry_eligible OR submission_started_at IS NOT NULL"
           )

    create index(:plc_registrations, ["COALESCE(retry_next_at, submission_started_at)", :did],
             name: :plc_registrations_retry_eligible_due,
             where: "retry_eligible AND completed_at IS NULL"
           )
  end
end
