defmodule Atoll.Blobs.Takedown do
  @moduledoc "An account/CID restriction that survives blob ownership withdrawal."
  use Ecto.Schema
  @primary_key false
  schema "blob_takedowns" do
    field :did, :string, primary_key: true
    field :cid, :binary, primary_key: true
    field :ref, :string, redact: true
  end
end
