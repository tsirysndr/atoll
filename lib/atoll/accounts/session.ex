defmodule Atoll.Accounts.Session do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "account_sessions" do
    field :did, :string
    field :refresh_hash, :binary, redact: true
    field :expires_at, :integer
  end
end
