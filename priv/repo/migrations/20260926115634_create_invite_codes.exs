defmodule Atoll.Repo.Migrations.CreateInviteCodes do
  use Ecto.Migration

  def change do
    create table(:invite_codes, primary_key: false) do
      add :code, :text, primary_key: true
      add :use_count, :integer, null: false
      add :remaining, :integer, null: false
      add :disabled, :boolean, null: false, default: false
      add :for_account, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:invite_codes, [:for_account])

    create constraint(:invite_codes, :invite_use_bounds,
             check: "use_count BETWEEN 1 AND 10000 AND remaining BETWEEN 0 AND use_count"
           )

    create table(:invite_uses, primary_key: false) do
      # Keep the historical redemption after account deletion; deletion never refunds a use.
      add :did, :text, primary_key: true
      add :code, references(:invite_codes, column: :code, type: :text), null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:invite_uses, [:code])
  end
end
