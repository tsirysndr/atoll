defmodule Atoll.Repo.Migrations.AddPendingPlcSigningKeys do
  use Ecto.Migration

  def change do
    alter table(:plc_updates) do
      add :signing_curve, :text
      add :signing_public_key, :binary
      add :expected_signing_key, :text
      add :signing_envelope, :binary
    end

    create constraint(:plc_updates, :pending_signing_key_shape,
             check:
               "(signing_curve IS NULL AND signing_public_key IS NULL AND expected_signing_key IS NULL AND signing_envelope IS NULL) OR (signing_curve IS NOT NULL AND signing_curve IN ('k256', 'p256') AND signing_public_key IS NOT NULL AND octet_length(signing_public_key) = 33 AND expected_signing_key IS NOT NULL AND (signing_envelope IS NULL OR octet_length(signing_envelope) = 61))"
           )

    create unique_index(:plc_updates, [:did],
             name: :plc_updates_one_retained_signing_key,
             where: "signing_envelope IS NOT NULL"
           )
  end
end
