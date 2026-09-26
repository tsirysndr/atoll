defmodule Atoll.Accounts.Profile do
  @moduledoc "Local account metadata and the source key pinned during migration provisioning."
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "account_profiles" do
    field :handle, :string
    field :email, :string, redact: true
    field :email_confirmed_at, :utc_datetime_usec
    field :email_confirmation_digest, :binary, redact: true
    field :email_confirmation_expires_at, :integer
    field :email_confirmation_requested_at, :integer
    field :import_curve, Ecto.Enum, values: [:k256, :p256]
    field :import_public_key, :binary
    field :import_head, :binary
    field :import_rev, :string
    timestamps(type: :utc_datetime_usec)
  end
end
