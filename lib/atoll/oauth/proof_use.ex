defmodule Atoll.OAuth.ProofUse do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:digest, :binary, autogenerate: false, redact: true}
  schema "oauth_dpop_uses" do
    field :expires_at, :integer
  end
end
