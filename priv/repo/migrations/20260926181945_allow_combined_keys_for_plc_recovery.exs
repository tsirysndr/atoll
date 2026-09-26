defmodule Atoll.Repo.Migrations.AllowCombinedKeysForPlcRecovery do
  use Ecto.Migration

  def up do
    drop constraint(:plc_updates, :one_pending_key_purpose)

    create constraint(:plc_updates, :one_pending_key_purpose,
             check:
               "recovery_expected_head IS NOT NULL OR signing_public_key IS NULL OR authority_public_key IS NULL"
           )
  end

  def down do
    drop constraint(:plc_updates, :one_pending_key_purpose)

    create constraint(:plc_updates, :one_pending_key_purpose,
             check: "signing_public_key IS NULL OR authority_public_key IS NULL"
           )
  end
end
