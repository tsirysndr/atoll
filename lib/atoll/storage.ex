defmodule Atoll.Storage do
  @moduledoc """
  Stores and retrieves verified, content-addressed blocks.
  """

  alias Atoll.{CID, Repo}
  alias Atoll.Storage.Block

  @spec put_block(binary(), binary()) ::
          :ok | {:error, :invalid_cid | :content_mismatch}
  def put_block(cid, data) when is_binary(cid) and is_binary(data) do
    with :ok <- CID.verify(cid, data) do
      Repo.insert!(
        %Block{cid: cid, data: data},
        on_conflict: :nothing,
        conflict_target: [:cid]
      )

      :ok
    end
  end

  @spec get_block(binary()) ::
          {:ok, binary()} | {:error, :invalid_cid | :not_found}
  def get_block(cid) when is_binary(cid) do
    with {:ok, _fields} <- CID.decode(cid) do
      case Repo.get(Block, cid) do
        nil -> {:error, :not_found}
        %Block{data: data} -> {:ok, data}
      end
    end
  end
end
