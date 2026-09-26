defmodule Atoll.Repo.Migrations.CreateImportedPlcRotationKeys do
  use Ecto.Migration

  def change do
    create table(:imported_plc_rotation_keys, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :curve, :string, null: false
      add :public_key, :binary, null: false
      add :verified_cid, :text, null: false
      add :envelope, :binary, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:imported_plc_rotation_keys, :valid_imported_rotation_key,
             check:
               "curve IN ('k256', 'p256') AND octet_length(public_key) = 33 AND octet_length(envelope) = 61"
           )
  end
end
