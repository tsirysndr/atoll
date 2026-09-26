defmodule Atoll.OAuth.PushedRequest do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:digest, :binary, autogenerate: false, redact: true}
  schema "oauth_pushed_requests" do
    field :issuer, :string
    field :client_id, :string
    field :parameters, :map, redact: true
    field :dpop_jkt, :string
    field :client_binding, :map
    field :expires_at, :integer
  end
end
