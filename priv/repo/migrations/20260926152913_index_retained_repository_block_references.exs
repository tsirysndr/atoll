defmodule Atoll.Repo.Migrations.IndexRetainedRepositoryBlockReferences do
  use Ecto.Migration

  def up do
    create table(:repository_block_refs, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :cid, :binary, primary_key: true
      add :revision_count, :bigint, null: false
    end

    create constraint(:repository_block_refs, :positive_revision_count,
             check: "revision_count > 0"
           )

    create index(:repository_block_refs, [:cid])

    # Freeze revision writes while backfilling and installing the transactional trigger.
    execute "LOCK TABLE repository_revisions IN SHARE ROW EXCLUSIVE MODE"

    execute """
    INSERT INTO repository_block_refs (did, cid, revision_count)
    SELECT r.did, b.cid, count(*) FROM repository_revisions r
    CROSS JOIN LATERAL (SELECT DISTINCT unnest(r.blocks) AS cid) b
    GROUP BY r.did, b.cid
    """

    execute """
    CREATE FUNCTION atoll_track_revision_blocks() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP IN ('DELETE', 'UPDATE') THEN
        DELETE FROM repository_block_refs WHERE did = OLD.did
          AND cid = ANY(OLD.blocks) AND revision_count = 1;
        UPDATE repository_block_refs SET revision_count = revision_count - 1
          WHERE did = OLD.did AND cid = ANY(OLD.blocks) AND revision_count > 1;
      END IF;
      IF TG_OP IN ('INSERT', 'UPDATE') THEN
        INSERT INTO repository_block_refs (did, cid, revision_count)
          SELECT NEW.did, cid, 1 FROM (SELECT DISTINCT unnest(NEW.blocks) AS cid) b ORDER BY cid
          ON CONFLICT (did, cid) DO UPDATE
          SET revision_count = repository_block_refs.revision_count + 1;
      END IF;
      RETURN NULL;
    END;
    $$
    """

    execute """
    CREATE TRIGGER atoll_revision_blocks
    AFTER INSERT OR UPDATE OR DELETE ON repository_revisions
    FOR EACH ROW EXECUTE FUNCTION atoll_track_revision_blocks()
    """
  end

  def down do
    execute "DROP TRIGGER atoll_revision_blocks ON repository_revisions"
    execute "DROP FUNCTION atoll_track_revision_blocks()"
    drop table(:repository_block_refs)
  end
end
