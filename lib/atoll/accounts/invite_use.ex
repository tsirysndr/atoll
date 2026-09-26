defmodule Atoll.Accounts.InviteUse do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "invite_uses" do
    field :code, :string, redact: true
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
