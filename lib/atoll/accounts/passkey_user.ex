defmodule Atoll.Accounts.PasskeyUser do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "account_passkey_users" do
    field :user_handle, :binary, redact: true
  end
end
