defmodule Atoll.Repositories.BlockReference do
  @moduledoc "Derived retained-revision membership counts; signed trees remain the authority for public proofs."
  use Ecto.Schema
  @primary_key false
  schema "repository_block_refs" do
    field :did, :string, primary_key: true
    field :cid, :binary, primary_key: true
    field :revision_count, :integer
  end
end
