defmodule Atoll.Repo.Migrations.IndexOauthSessionsForKeyChecks do
  use Ecto.Migration

  def change do
    create index(:oauth_sessions, [:client_id, :id],
             where: "client_binding IS NOT NULL",
             name: :oauth_sessions_key_check_cursor
           )
  end
end
