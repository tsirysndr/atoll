defmodule Atoll.Repo.Migrations.AddEmailConfirmationTokens do
  use Ecto.Migration

  def change do
    alter table(:account_profiles) do
      add :email_confirmation_digest, :binary
      add :email_confirmation_expires_at, :bigint
      add :email_confirmation_requested_at, :bigint
    end

    create constraint(:account_profiles, :email_confirmation_token_shape,
             check:
               "(email_confirmation_digest IS NULL AND email_confirmation_expires_at IS NULL) OR (email_confirmation_digest IS NOT NULL AND octet_length(email_confirmation_digest) = 32 AND email_confirmation_expires_at IS NOT NULL AND email_confirmation_requested_at IS NOT NULL)"
           )
  end
end
