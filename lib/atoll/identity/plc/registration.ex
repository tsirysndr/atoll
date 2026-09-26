defmodule Atoll.Identity.PLC.Registration do
  @moduledoc "Persisted signed genesis and encrypted rotation key; confirmation records directory acceptance."
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "plc_registrations" do
    field :operation, :map
    field :cid, :string
    field :rotation_curve, Ecto.Enum, values: [:k256, :p256]
    field :rotation_public_key, :binary
    field :rotation_envelope, :binary, redact: true
    field :confirmed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
