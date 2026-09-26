defmodule Atoll.Repo.Migrations.CreateServiceTokenUses do
  use Ecto.Migration

  def change do
    create table(:service_token_uses, primary_key: false) do
      add :digest, :binary, primary_key: true
      add :expires_at, :bigint, null: false
    end

    create index(:service_token_uses, [:expires_at])

    create constraint(:service_token_uses, :service_token_digest_length,
             check: "octet_length(digest) = 32"
           )

    create constraint(:service_token_uses, :service_token_expiration, check: "expires_at > 0")
  end
end
