defmodule Atoll.OAuth.RefreshUse do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:digest, :binary, autogenerate: false, redact: true}
  schema "oauth_refresh_uses" do
    field :session_id, :string, redact: true
    field :expires_at, :integer
  end
end
