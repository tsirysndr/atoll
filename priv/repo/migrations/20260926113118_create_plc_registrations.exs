defmodule Atoll.Repo.Migrations.CreatePlcRegistrations do
  use Ecto.Migration

  def change do
    create table(:plc_registrations, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :operation, :map, null: false
      add :cid, :text, null: false
      add :rotation_curve, :string, null: false
      add :rotation_public_key, :binary, null: false
      add :rotation_envelope, :binary, null: false
      add :confirmed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:plc_registrations, :valid_rotation_key,
             check:
               "rotation_curve IN ('k256', 'p256') AND octet_length(rotation_public_key) = 33 AND octet_length(rotation_envelope) = 61"
           )
  end
end
