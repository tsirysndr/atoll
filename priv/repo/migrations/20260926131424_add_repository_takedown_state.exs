defmodule Atoll.Repo.Migrations.AddRepositoryTakedownState do
  use Ecto.Migration

  def up do
    alter table(:repositories) do
      add :pre_takedown_status, :string
      add :takedown_ref, :text
    end

    # Older takedowns did not retain their previous availability. Restoring one
    # must not publish a repository whose previous state is unknown.
    execute "UPDATE repositories SET pre_takedown_status = 'deactivated' WHERE status = 'takendown'"

    create constraint(:repositories, :repository_takedown_state,
             check: """
             (status = 'takendown' AND pre_takedown_status IS NOT NULL
               AND pre_takedown_status IN ('active', 'deactivated', 'suspended'))
             OR (status <> 'takendown' AND pre_takedown_status IS NULL AND takedown_ref IS NULL)
             """
           )

    create constraint(:repositories, :repository_takedown_ref_size,
             check: "takedown_ref IS NULL OR octet_length(takedown_ref) <= 2000"
           )
  end

  def down do
    drop constraint(:repositories, :repository_takedown_state)
    drop constraint(:repositories, :repository_takedown_ref_size)

    alter table(:repositories) do
      remove :pre_takedown_status
      remove :takedown_ref
    end
  end
end
