defmodule Atoll.Identity.PLC.Update do
  @moduledoc "Durable signed PLC update; confirmation and local completion are separate."
  use Ecto.Schema
  @primary_key false
  schema "plc_updates" do
    field :did, :string, primary_key: true
    field :cid, :string, primary_key: true
    field :previous, :map
    field :operation, :map
    field :confirmed_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
