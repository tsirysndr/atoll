defmodule Atoll.Repo.Migrations.CreateOauthPushedRequests do
  use Ecto.Migration

  def change do
    create table(:oauth_pushed_requests, primary_key: false) do
      add :digest, :binary, primary_key: true
      add :issuer, :text, null: false
      add :client_id, :text, null: false
      add :parameters, :map, null: false
      add :dpop_jkt, :text, null: false
      add :client_binding, :map
      add :expires_at, :bigint, null: false
    end

    create index(:oauth_pushed_requests, [:expires_at, :digest])

    create constraint(:oauth_pushed_requests, :oauth_pushed_request_shape,
             check: "octet_length(digest) = 32 AND expires_at > 0 AND octet_length(dpop_jkt) = 43"
           )

    create table(:oauth_pkce_uses, primary_key: false) do
      add :digest, :binary, primary_key: true
      add :expires_at, :bigint, null: false
    end

    create index(:oauth_pkce_uses, [:expires_at, :digest])

    create constraint(:oauth_pkce_uses, :oauth_pkce_use_shape,
             check: "octet_length(digest) = 32 AND expires_at > 0"
           )
  end
end
