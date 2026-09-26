defmodule Atoll.Repo.Migrations.AddRepositoryStatus do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :status, :string, null: false, default: "active"
    end

    create constraint(:repositories, :repository_status,
             check: "status IN ('active', 'deactivated', 'takendown', 'suspended')"
           )
  end
end
