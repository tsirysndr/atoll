defmodule Atoll.Accounts.TOTPFactor do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "account_totp_factors" do
    field :version, :string, redact: true
    field :envelope, :binary, redact: true
    field :credential_digest, :binary, redact: true
    field :pending_expires_at, :integer
    field :confirmed_at, :integer
    field :last_used_step, :integer
    field :attempts, :integer, default: 0
    field :window_started_at, :integer, default: 0
  end
end
