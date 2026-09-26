defmodule Atoll.Repo.Migrations.CreateOauthClientAssertionUses do
  use Ecto.Migration

  def change do
    create table(:oauth_client_assertion_uses, primary_key: false) do
      add :digest, :binary, primary_key: true
      add :expires_at, :bigint, null: false
    end

    create index(:oauth_client_assertion_uses, [:expires_at, :digest])

    create constraint(:oauth_client_assertion_uses, :oauth_client_assertion_use_shape,
             check: "octet_length(digest) = 32 AND expires_at > 0"
           )
  end
end
