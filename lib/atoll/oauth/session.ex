defmodule Atoll.OAuth.Session do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false, redact: true}
  schema "oauth_sessions" do
    field :did, :string
    field :source_session_id, :string, redact: true
    field :issuer, :string
    field :client_id, :string
    field :scope, :string
    field :dpop_jkt, :string
    field :client_binding, :map
    field :refresh_digest, :binary, redact: true
    field :expires_at, :integer
  end
end
