defmodule Atoll.Repo.Migrations.AddSignupCompletionToPlcRegistrations do
  use Ecto.Migration

  def change do
    alter table(:plc_registrations) do
      add :completed_at, :utc_datetime_usec
    end

    create constraint(:plc_registrations, :completion_requires_confirmation,
             check: "completed_at IS NULL OR confirmed_at IS NOT NULL"
           )
  end
end
