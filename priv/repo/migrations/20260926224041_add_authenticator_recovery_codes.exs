defmodule Atoll.Repo.Migrations.AddAuthenticatorRecoveryCodes do
  use Ecto.Migration

  def change do
    alter table(:account_totp_factors) do
      add :recovery_hashes, {:array, :binary}, null: false, default: []
    end

    create constraint(:account_totp_factors, :totp_recovery_bound,
             check:
               "cardinality(recovery_hashes) <= 10 AND array_position(recovery_hashes, NULL) IS NULL"
           )
  end
end
