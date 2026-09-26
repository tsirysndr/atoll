defmodule Atoll.Repo.Migrations.TrackInviteCodeCreator do
  use Ecto.Migration

  def change do
    alter table(:invite_codes) do
      add :created_by, :text, null: false, default: "admin"
    end

    create index(:invite_codes, [:created_by])
  end
end
