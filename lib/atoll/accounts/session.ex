defmodule Atoll.Accounts.Session do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "account_sessions" do
    field :did, :string
    field :app_password_id, :binary_id
    field :access_scope, :string, default: "com.atproto.access"
    field :refresh_hash, :binary, redact: true
    field :expires_at, :integer
  end
end
