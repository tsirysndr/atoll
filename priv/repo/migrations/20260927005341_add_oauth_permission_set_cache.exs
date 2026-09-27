defmodule Atoll.Repo.Migrations.AddOauthPermissionSetCache do
  use Ecto.Migration

  def change do
    create table(:oauth_permission_sets, primary_key: false) do
      add :nsid, :text, primary_key: true
      add :document, :map, null: false
      add :provenance, :map, null: false
      add :fetched_at, :bigint, null: false
      add :retry_at, :bigint, null: false
    end

    create index(:oauth_permission_sets, [:fetched_at, :nsid])

    create constraint(:oauth_permission_sets, :oauth_permission_set_shape,
             check:
               "fetched_at > 0 AND retry_at >= fetched_at AND jsonb_typeof(document) = 'object' AND jsonb_typeof(provenance) = 'object' AND octet_length(document::text) <= 524288"
           )
  end
end
