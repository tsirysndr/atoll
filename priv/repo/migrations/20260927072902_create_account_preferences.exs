defmodule Atoll.Repo.Migrations.CreateAccountPreferences do
  use Ecto.Migration

  def change do
    create table(:account_preferences, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :preferences, :jsonb, null: false, default: "[]"
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:account_preferences, :preferences_are_an_array,
             check: "jsonb_typeof(preferences) = 'array'"
           )
  end
end
