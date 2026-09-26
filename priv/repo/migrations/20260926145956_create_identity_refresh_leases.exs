defmodule Atoll.Repo.Migrations.CreateIdentityRefreshLeases do
  use Ecto.Migration

  def change do
    create table(:identity_refresh_leases, primary_key: false) do
      add :did, references(:repositories, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :token, :binary, null: false
      add :leased_until, :utc_datetime_usec, null: false
      add :next_attempt_at, :utc_datetime_usec, null: false
    end

    create constraint(:identity_refresh_leases, :refresh_token_length,
             check: "octet_length(token) = 32"
           )
  end
end
