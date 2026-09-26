defmodule Atoll.Blobs.Reference do
  use Ecto.Schema
  @primary_key false
  schema "blob_references" do
    field :did, :string, primary_key: true
    field :path, :string, primary_key: true
    field :cid, :binary, primary_key: true
    field :mime_type, :string
    field :size, :integer
    field :rev, :string
  end
end
