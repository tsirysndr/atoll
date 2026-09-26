defmodule Atoll.Repo.Migrations.AllowRetiringPlcSignupKey do
  use Ecto.Migration

  def up do
    alter table(:plc_registrations) do
      modify :rotation_envelope, :binary, null: true
      add :rotation_retired_at, :utc_datetime_usec
    end

    create constraint(:plc_registrations, :valid_rotation_retirement,
             check:
               "(rotation_retired_at IS NULL AND rotation_envelope IS NOT NULL) OR " <>
                 "(rotation_retired_at IS NOT NULL AND rotation_envelope IS NULL AND completed_at IS NOT NULL)"
           )
  end

  def down do
    # Refuse to discard retirement history or invent erased private material.
    alter table(:plc_registrations) do
      modify :rotation_envelope, :binary, null: false
    end

    drop constraint(:plc_registrations, :valid_rotation_retirement)

    alter table(:plc_registrations) do
      remove :rotation_retired_at
    end
  end
end
