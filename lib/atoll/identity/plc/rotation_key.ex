defmodule Atoll.Identity.PLC.RotationKey do
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "imported_plc_rotation_keys" do
    field :curve, Ecto.Enum, values: [:k256, :p256]
    field :public_key, :binary
    field :verified_cid, :string
    field :envelope, :binary, redact: true
    timestamps(type: :utc_datetime_usec)
  end
end
