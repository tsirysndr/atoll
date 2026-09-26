defmodule Atoll.OAuth.ClientAssertionUse do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:digest, :binary, autogenerate: false, redact: true}
  schema "oauth_client_assertion_uses" do
    field :expires_at, :integer
  end
end
