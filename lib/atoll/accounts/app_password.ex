defmodule Atoll.Accounts.AppPassword do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "app_passwords" do
    field :did, :string
    field :name, :string
    field :digest, :binary, redact: true
    field :privileged, :boolean, default: false
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
