defmodule Atoll.Repo.Migrations.SnapshotOauthPermissionSets do
  use Ecto.Migration

  def change do
    for table <- [
          :oauth_pushed_requests,
          :oauth_authorization_codes,
          :oauth_sessions,
          :oauth_access_tokens
        ] do
      alter table(table) do
        add :permission_sets, :map, null: false, default: %{}
      end

      create constraint(table, "#{table}_permission_sets_shape",
               check:
                 "jsonb_typeof(permission_sets) = 'object' AND octet_length(permission_sets::text) <= 2097152"
             )
    end
  end
end
