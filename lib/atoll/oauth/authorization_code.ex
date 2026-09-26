defmodule Atoll.OAuth.AuthorizationCode do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:digest, :binary, autogenerate: false, redact: true}
  schema "oauth_authorization_codes" do
    field :did, :string
    field :source_session_id, :string, redact: true
    field :issuer, :string
    field :client_id, :string
    field :redirect_uri, :string, redact: true
    field :scope, :string
    field :code_challenge, :string, redact: true
    field :dpop_jkt, :string
    field :client_binding, :map
    field :refresh_allowed, :boolean
    field :expires_at, :integer
  end
end
