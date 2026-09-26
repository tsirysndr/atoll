defmodule Atoll.Repo.Migrations.CreateAccountProfiles do
  use Ecto.Migration

  def change do
    create table(:account_profiles, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :handle, :text, null: false
      add :email, :text
      add :email_confirmed_at, :utc_datetime_usec
      add :import_curve, :string
      add :import_public_key, :binary
      add :import_head, :binary
      add :import_rev, :string, size: 13
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:account_profiles, [:handle])
    create unique_index(:account_profiles, [:email])
    create constraint(:account_profiles, :normalized_handle, check: "handle = lower(handle)")

    create constraint(:account_profiles, :normalized_email,
             check: "email IS NULL OR email = lower(email)"
           )

    create constraint(:account_profiles, :import_signing_key,
             check:
               "(import_curve IS NULL AND import_public_key IS NULL) OR (import_curve IS NOT NULL AND import_public_key IS NOT NULL AND import_curve IN ('k256', 'p256') AND octet_length(import_public_key) = 33)"
           )
  end
end
