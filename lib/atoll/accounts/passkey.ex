defmodule Atoll.Accounts.Passkey do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "account_passkeys" do
    field :did, :string
    field :credential_id, :binary, redact: true
    field :public_key, :binary, redact: true
    field :rp_id, :string
    field :name, :string
    field :sign_count, :integer
    field :backup_eligible, :boolean
    field :backup_state, :boolean
    field :created_at, :integer
    field :last_used_at, :integer
  end
end
