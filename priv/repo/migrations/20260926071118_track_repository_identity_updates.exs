defmodule Atoll.Repo.Migrations.TrackRepositoryIdentityUpdates do
  use Ecto.Migration

  def up do
    drop constraint(:repository_events, :valid_kind)

    create constraint(:repository_events, :valid_kind,
             check: "kind IN ('commit', 'sync', 'account', 'identity')"
           )

    create table(:repository_identities, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :fingerprint, :binary, null: false
      add :handle, :text, null: false
    end

    create constraint(:repository_identities, :fingerprint_size,
             check: "octet_length(fingerprint) = 32"
           )
  end

  def down do
    drop table(:repository_identities)
    # Refuse rollback while identity events exist, rather than silently deleting history.
    drop constraint(:repository_events, :valid_kind)

    create constraint(:repository_events, :valid_kind,
             check: "kind IN ('commit', 'sync', 'account')"
           )
  end
end
