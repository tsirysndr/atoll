defmodule Atoll.Repo.Migrations.IndexInviteListingOrder do
  use Ecto.Migration

  def change do
    execute "CREATE INDEX invite_codes_recent ON invite_codes (inserted_at DESC, code ASC)",
            "DROP INDEX invite_codes_recent"

    execute "CREATE INDEX invite_codes_usage ON invite_codes ((use_count - remaining) DESC, inserted_at DESC, code ASC)",
            "DROP INDEX invite_codes_usage"

    execute "CREATE INDEX invite_codes_owner_recent ON invite_codes (for_account, inserted_at DESC, code ASC)",
            "DROP INDEX invite_codes_owner_recent"
  end
end
