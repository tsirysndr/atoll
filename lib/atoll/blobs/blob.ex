defmodule Atoll.Blobs.Blob do
  use Ecto.Schema
  @primary_key false
  schema "repository_blobs" do
    field :did, :string, primary_key: true
    field :cid, :binary, primary_key: true
    field :backend, Ecto.Enum, values: [:postgres, :s3]
    field :mime_type, :string
    field :size, :integer
    field :staged_at, :utc_datetime_usec
  end
end
