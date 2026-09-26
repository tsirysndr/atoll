defmodule Atoll.Repositories.Record do
  use Ecto.Schema
  @primary_key false
  schema "repository_records" do
    field :did, :string, primary_key: true
    field :path, :string, primary_key: true
    field :cid, :binary
  end
end
