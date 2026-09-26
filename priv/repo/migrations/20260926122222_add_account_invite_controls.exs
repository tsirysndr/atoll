defmodule Atoll.Repo.Migrations.AddAccountInviteControls do
  use Ecto.Migration

  def change do
    alter table(:account_profiles) do
      add :invites_disabled, :boolean, null: false, default: false
      add :invite_control_note, :text
      add :invites_updated_at, :utc_datetime_usec
    end
  end
end
