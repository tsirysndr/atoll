defmodule Atoll.Repo.Migrations.AddRevisionSigningKeys do
  use Ecto.Migration

  def up do
    alter table(:repository_revisions) do
      add :signing_curve, :string
      add :signing_public_key, :binary
    end

    flush()
    # Earlier versions have no repository signing-key transition API: all retained
    # local revisions use the repository's pinned key (migration imports re-sign).
    execute """
    UPDATE repository_revisions AS revision
    SET signing_curve = repository.curve, signing_public_key = repository.public_key
    FROM repositories AS repository WHERE repository.did = revision.did
    """

    alter table(:repository_revisions) do
      modify :signing_curve, :string, null: false
      modify :signing_public_key, :binary, null: false
    end

    create constraint(:repository_revisions, :revision_signing_key,
             check: "signing_curve IN ('k256', 'p256') AND octet_length(signing_public_key) = 33"
           )
  end

  def down do
    drop constraint(:repository_revisions, :revision_signing_key)

    alter table(:repository_revisions) do
      remove :signing_curve
      remove :signing_public_key
    end
  end
end
