defmodule Atoll.Repo.Migrations.AddEmailUpdateTokens do
  use Ecto.Migration

  def change do
    alter table(:account_profiles) do
      add :email_update_digest, :binary
      add :email_update_expires_at, :bigint
      add :email_update_requested_at, :bigint
    end

    create constraint(:account_profiles, :email_update_token_shape,
             check:
               "(email_update_digest IS NULL AND email_update_expires_at IS NULL) OR (email_update_digest IS NOT NULL AND octet_length(email_update_digest) = 32 AND email_update_expires_at IS NOT NULL AND email_update_requested_at IS NOT NULL)"
           )
  end
end
