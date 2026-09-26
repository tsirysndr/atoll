defmodule Atoll.Accounts.ReservedSigningKey do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:public_key, :string, autogenerate: false}
  schema "reserved_signing_keys" do
    field :did, :string
    field :envelope, :binary, redact: true
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
