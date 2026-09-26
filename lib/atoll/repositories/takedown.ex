defmodule Atoll.Repositories.Takedown do
  @moduledoc "An operator restriction on record API visibility, independent of signed repository data."
  use Ecto.Schema
  @primary_key false
  schema "record_takedowns" do
    field :did, :string, primary_key: true
    field :path, :string, primary_key: true
    field :cid, :binary
    field :ref, :string, redact: true
  end
end
