defmodule Atoll.Repo.Migrations.AddPlcSignatureChallenges do
  use Ecto.Migration

  def change do
    alter table(:account_profiles) do
      add :plc_signature_digest, :binary
      add :plc_signature_expires_at, :bigint
      add :plc_signature_requested_at, :bigint
    end
  end
end
