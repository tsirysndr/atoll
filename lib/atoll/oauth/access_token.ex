defmodule Atoll.OAuth.AccessToken do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:digest, :binary, autogenerate: false, redact: true}
  schema "oauth_access_tokens" do
    field :permission_sets, :map, default: %{}
    field :session_id, :string, redact: true
    field :scope, :string
    field :expires_at, :integer
  end
end
