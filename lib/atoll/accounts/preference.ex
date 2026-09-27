defmodule Atoll.Accounts.Preference do
  @moduledoc "Private per-account application preference document."
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "account_preferences" do
    field :preferences, {:array, :map}, default: []
    timestamps(type: :utc_datetime_usec)
  end
end
