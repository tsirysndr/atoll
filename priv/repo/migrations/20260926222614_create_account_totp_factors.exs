defmodule Atoll.Repo.Migrations.CreateAccountTotpFactors do
  use Ecto.Migration

  def change do
    create table(:account_totp_factors, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :version, :text, null: false
      add :envelope, :binary, null: false
      add :credential_digest, :binary, null: false
      add :pending_expires_at, :bigint
      add :confirmed_at, :bigint
      add :last_used_step, :bigint, null: false, default: -1
      add :attempts, :integer, null: false, default: 0
      add :window_started_at, :bigint, null: false, default: 0
    end

    create constraint(:account_totp_factors, :totp_factor_shape,
             check:
               "octet_length(envelope) = 49 AND octet_length(credential_digest) = 32 AND length(version) = 43 AND last_used_step >= -1 AND attempts BETWEEN 0 AND 5 AND window_started_at >= 0 AND ((confirmed_at IS NULL AND pending_expires_at IS NOT NULL) OR (confirmed_at IS NOT NULL AND pending_expires_at IS NULL))"
           )
  end
end
