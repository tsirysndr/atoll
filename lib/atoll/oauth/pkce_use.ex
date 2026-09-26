defmodule Atoll.OAuth.PKCEUse do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:digest, :binary, autogenerate: false, redact: true}
  schema "oauth_pkce_uses" do
    field :expires_at, :integer
  end
end
