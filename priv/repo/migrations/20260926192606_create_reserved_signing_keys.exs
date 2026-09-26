defmodule Atoll.Repo.Migrations.CreateReservedSigningKeys do
  use Ecto.Migration

  def change do
    create table(:reserved_signing_keys, primary_key: false) do
      add :public_key, :text, primary_key: true
      add :did, :text
      add :envelope, :binary, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:reserved_signing_keys, [:did])

    create constraint(:reserved_signing_keys, :reserved_signing_key_shape,
             check:
               "octet_length(envelope) = 61 AND octet_length(public_key) <= 256 AND (did IS NULL OR octet_length(did) <= 2048)"
           )
  end
end
