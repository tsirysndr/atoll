defmodule Atoll.Identity.Observation do
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "repository_identities" do
    field :fingerprint, :binary
    field :handle, :string
  end
end
