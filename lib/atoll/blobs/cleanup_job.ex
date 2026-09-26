defmodule Atoll.Blobs.CleanupJob do
  use Ecto.Schema
  @primary_key false
  schema "blob_cleanup_jobs" do
    field :cid, :binary, primary_key: true
    field :backend, Ecto.Enum, values: [:postgres, :s3], primary_key: true
    field :queued_at, :utc_datetime_usec
  end
end
