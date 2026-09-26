defmodule Atoll.Accounts.Credential do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:did, :string, autogenerate: false}
  schema "repository_credentials" do
    field :password_hash, :string, redact: true
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
