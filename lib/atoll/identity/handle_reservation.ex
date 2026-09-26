defmodule Atoll.Identity.HandleReservation do
  use Ecto.Schema
  @primary_key {:handle, :string, autogenerate: false}
  schema "handle_change_reservations" do
    field :did, :string
    field :cid, :string
    timestamps(type: :utc_datetime_usec)
  end
end
