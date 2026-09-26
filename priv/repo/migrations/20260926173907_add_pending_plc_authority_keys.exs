defmodule Atoll.Repo.Migrations.AddPendingPlcAuthorityKeys do
  use Ecto.Migration

  def change do
    alter table(:plc_updates) do
      add :authority_curve, :text
      add :authority_public_key, :binary
      add :expected_authority_key, :text
      add :authority_envelope, :binary
    end

    create constraint(:plc_updates, :pending_authority_key_shape,
             check:
               "(authority_curve IS NULL AND authority_public_key IS NULL AND expected_authority_key IS NULL AND authority_envelope IS NULL) OR (authority_curve IS NOT NULL AND authority_curve IN ('k256', 'p256') AND authority_public_key IS NOT NULL AND octet_length(authority_public_key) = 33 AND expected_authority_key IS NOT NULL AND (authority_envelope IS NULL OR octet_length(authority_envelope) = 61))"
           )

    create constraint(:plc_updates, :one_pending_key_purpose,
             check: "signing_public_key IS NULL OR authority_public_key IS NULL"
           )

    create unique_index(:plc_updates, [:did],
             name: :plc_updates_one_retained_authority_key,
             where: "authority_envelope IS NOT NULL"
           )
  end
end
