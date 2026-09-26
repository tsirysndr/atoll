defmodule Atoll.Identity.PLC.Update do
  @moduledoc "Durable signed PLC update; confirmation and local completion are separate."
  use Ecto.Schema
  @primary_key false
  schema "plc_updates" do
    field :did, :string, primary_key: true
    field :cid, :string, primary_key: true
    field :previous, :map
    field :operation, :map
    field :signing_curve, Ecto.Enum, values: [:k256, :p256]
    field :signing_public_key, :binary
    field :expected_signing_key, :string
    field :signing_envelope, :binary, redact: true
    field :authority_curve, Ecto.Enum, values: [:k256, :p256]
    field :authority_public_key, :binary
    field :expected_authority_key, :string
    field :authority_envelope, :binary, redact: true
    field :recovery_expected_head, :string
    field :recovery_deadline, :utc_datetime_usec
    field :recovery_nullified_cids, {:array, :string}
    field :nullified_at, :utc_datetime_usec
    field :nullified_head, :string
    field :confirmed_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
