defmodule Atoll.OAuth.PermissionSetCache do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:nsid, :string, autogenerate: false}
  schema "oauth_permission_sets" do
    field :document, :map
    field :provenance, :map
    field :fetched_at, :integer
    field :retry_at, :integer
  end
end
