defmodule Atoll.Repositories.EventDependency do
  use Ecto.Schema
  @primary_key false
  schema "event_revision_dependencies" do
    field :seq, :integer, primary_key: true
    field :head, :binary, primary_key: true
    field :did, :string
  end
end
