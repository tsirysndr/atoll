defmodule Atoll.Repo.Migrations.AddAccountDeletionTokens do
  use Ecto.Migration

  def change do
    alter table(:account_profiles) do
      add :deletion_digest, :binary
      add :deletion_expires_at, :bigint
      add :deletion_requested_at, :bigint
    end

    create constraint(:account_profiles, :deletion_token_shape,
             check:
               "(deletion_digest IS NULL AND deletion_expires_at IS NULL) OR (deletion_digest IS NOT NULL AND octet_length(deletion_digest) = 32 AND deletion_expires_at IS NOT NULL AND deletion_requested_at IS NOT NULL)"
           )
  end
end
