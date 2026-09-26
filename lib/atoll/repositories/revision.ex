defmodule Atoll.Repositories.Revision do
  use Ecto.Schema
  @primary_key false
  schema "repository_revisions" do
    field :did, :string, primary_key: true
    field :rev, :string, primary_key: true
    field :head, :binary
    field :blocks, {:array, :binary}
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
