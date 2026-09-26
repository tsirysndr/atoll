defmodule Atoll.Repo.Migrations.AddPasswordResetTokens do
  use Ecto.Migration

  def change do
    alter table(:account_profiles) do
      add :password_reset_digest, :binary
      add :password_reset_expires_at, :bigint
      add :password_reset_requested_at, :bigint
    end

    create unique_index(:account_profiles, [:password_reset_digest])

    create constraint(:account_profiles, :password_reset_token_shape,
             check:
               "(password_reset_digest IS NULL AND password_reset_expires_at IS NULL) OR (password_reset_digest IS NOT NULL AND octet_length(password_reset_digest) = 32 AND password_reset_expires_at IS NOT NULL AND password_reset_requested_at IS NOT NULL)"
           )
  end
end
