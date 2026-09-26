defmodule Atoll.Repo.Migrations.CreateRepositoryEvents do
  use Ecto.Migration

  def change do
    create table(:repository_events, primary_key: false) do
      add :seq, :bigserial, primary_key: true
      add :did, :text, null: false
      add :kind, :text, null: false
      add :payload, :binary, null: false
      add :time, :utc_datetime_usec, null: false
    end

    create constraint(:repository_events, :valid_kind,
             check: "kind IN ('commit', 'sync', 'account')"
           )
  end
end
