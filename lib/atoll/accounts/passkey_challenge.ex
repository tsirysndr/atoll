defmodule Atoll.Accounts.PasskeyChallenge do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:digest, :binary, autogenerate: false, redact: true}
  schema "account_passkey_challenges" do
    field :browser_hash, :binary, redact: true
    field :challenge, :binary, redact: true
    field :kind, :string
    field :origin, :string
    field :rp_id, :string
    field :did, :string
    field :source_session_id, :string, redact: true
    field :credential_digest, :binary, redact: true
    field :totp_version, :string, redact: true
    field :name, :string
    field :expires_at, :integer
  end
end
