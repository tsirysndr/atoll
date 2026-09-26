defmodule Atoll.Repo.Migrations.AddEmailAuthenticationFactor do
  use Ecto.Migration

  def change do
    alter table(:account_profiles) do
      add :email_auth_factor, :boolean, null: false, default: false
      add :auth_factor_digest, :binary
      add :auth_factor_expires_at, :bigint
      add :auth_factor_requested_at, :bigint
    end

    create constraint(:account_profiles, :email_factor_confirmed,
             check:
               "NOT email_auth_factor OR (email IS NOT NULL AND email_confirmed_at IS NOT NULL)"
           )

    create constraint(:account_profiles, :auth_factor_token_shape,
             check:
               "(auth_factor_digest IS NULL AND auth_factor_expires_at IS NULL) OR (auth_factor_digest IS NOT NULL AND octet_length(auth_factor_digest) = 32 AND auth_factor_expires_at IS NOT NULL AND auth_factor_requested_at IS NOT NULL)"
           )
  end
end
