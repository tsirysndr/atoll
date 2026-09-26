defmodule Atoll.Repo.Migrations.AddSignupRetryLeases do
  use Ecto.Migration

  def change do
    alter table(:plc_registrations) do
      add :retry_token, :binary
      add :retry_leased_until, :utc_datetime_usec
      add :retry_next_at, :utc_datetime_usec
    end

    create constraint(:plc_registrations, :signup_retry_lease_shape,
             check:
               "(retry_token IS NULL AND retry_leased_until IS NULL AND retry_next_at IS NULL) OR " <>
                 "(retry_token IS NOT NULL AND octet_length(retry_token) = 32 AND retry_leased_until IS NOT NULL AND retry_next_at IS NOT NULL)"
           )

    create index(:plc_registrations, ["COALESCE(retry_next_at, submission_started_at)", :did],
             name: :plc_registrations_retry_due,
             where: "submission_started_at IS NOT NULL AND completed_at IS NULL"
           )
  end
end
