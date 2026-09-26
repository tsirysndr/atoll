defmodule Atoll.Accounts.Invite do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:code, :string, autogenerate: false, redact: true}
  schema "invite_codes" do
    field :use_count, :integer
    field :remaining, :integer
    field :disabled, :boolean, default: false
    field :for_account, :string
    field :created_by, :string, default: "admin"
    timestamps(type: :utc_datetime_usec)
  end
end
