defmodule Atoll.Storage.Block do
  @moduledoc """
  A stored content-addressed block.
  """

  use Ecto.Schema

  @primary_key {:cid, :binary, autogenerate: false}
  schema "blocks" do
    field :data, :binary
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
