defmodule Atoll.Accounts.ServiceTokenUse do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:digest, :binary, autogenerate: false, redact: true}
  schema "service_token_uses" do
    field :expires_at, :integer
  end
end
