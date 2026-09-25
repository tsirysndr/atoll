defmodule Atoll.Storage do
  @moduledoc """
  Stores and retrieves verified, content-addressed blocks and CBOR nodes.
  """

  alias Atoll.{CBOR, CID, Repo}
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

  @doc """
  Encodes and stores a CBOR node, returning its binary CID.

  Validates the encoded value against the decoder's supported limits before
  storing it. Does not validate record Lexicons or account ownership.
  """
  @spec put_node(term()) :: {:ok, binary()} | {:error, :invalid_cbor}
  def put_node(value) do
    with {:ok, data} <- encode_node(value),
         {:ok, _decoded} <- CBOR.decode(data) do
      cid = CID.create(data, :dag_cbor)
      :ok = put_block(cid, data)

      {:ok, cid}
    end
  end

  @doc """
  Fetches a CBOR node and verifies its stored bytes before decoding.
  """
  @spec get_node(binary()) ::
          {:ok, term()}
          | {:error,
             :invalid_cid
             | :unsupported_codec
             | :not_found
             | :content_mismatch
             | :invalid_cbor}
  def get_node(cid) when is_binary(cid) do
    with {:ok, %{codec: :dag_cbor}} <- CID.decode(cid),
         {:ok, data} <- get_block(cid),
         :ok <- CID.verify(cid, data) do
      CBOR.decode(data)
    else
      {:ok, %{codec: :raw}} -> {:error, :unsupported_codec}
      {:error, _reason} = error -> error
    end
  end

  defp encode_node(value) do
    {:ok, CBOR.encode!(value)}
  rescue
    ArgumentError -> {:error, :invalid_cbor}
  end
end
