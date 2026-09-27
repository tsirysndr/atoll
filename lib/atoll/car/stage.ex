defmodule Atoll.CAR.Stage do
  @moduledoc """
  Request-scoped disk staging for validated CAR blocks. No public storage writes.
  The callback must finish using the stage before returning; its file is then
  closed and removed even on exceptions. Block bodies and the CID/offset index
  stay on disk; only bounded decoder and index metadata remain in memory. VM/host crashes may leave
  private temporary files for operational cleanup.
  """
  alias Atoll.{CID, CAR.Decoder}
  alias Atoll.CAR.StageIndex
  defstruct [:io, :index, roots: [], size: 0, blocks: 0]

  def with_chunks(chunks, consume, opts \\ []) when is_function(consume, 1) do
    decoder = Decoder.new(Keyword.take(opts, [:max_bytes, :max_blocks]))

    with_file(opts, decoder.max_blocks, fn io, index ->
      stage(chunks, decoder, %__MODULE__{io: io, index: index}, consume)
    end)
  end

  @doc "Stage a stateful reader returning {:more | :ok, bytes, state} or {:error, reason, state}."
  def with_reader(source, next, consume, opts \\ []) do
    decoder = Decoder.new(Keyword.take(opts, [:max_bytes, :max_blocks]))

    with_file(opts, decoder.max_blocks, fn io, index ->
      read_source(source, next, decoder, %__MODULE__{io: io, index: index}, consume)
    end)
  end

  defp read_source(source, next, decoder, staged, consume) do
    case next.(source) do
      {status, bytes, source} when status in [:ok, :more] ->
        case Decoder.feed(decoder, bytes, staged, &store/2) do
          {:ok, decoder, staged} when status == :more ->
            read_source(source, next, decoder, staged, consume)

          {:ok, decoder, staged} ->
            case Decoder.finish(decoder) do
              :ok -> consume.(staged, source)
              {:error, reason} -> {:error, reason, source}
            end

          {:error, reason} ->
            {:error, reason, source}
        end

      {:error, _, _} = error ->
        error
    end
  catch
    :car_staging_unavailable -> {:error, :car_staging_unavailable, source}
  end

  defp with_file(opts, max_blocks, callback) do
    parent = Keyword.get(opts, :directory, System.tmp_dir!())

    case Atoll.CAR.StageLease.open(parent) do
      {:ok, lease, io, index_io} ->
        try do
          case StageIndex.new(index_io, max_blocks) do
            {:ok, index} -> callback.(io, index)
            _ -> {:error, :car_staging_unavailable}
          end
        after
          Atoll.CAR.StageLease.close(lease)
        end

      error ->
        error
    end
  end

  @doc "Read a hash-verified staged block while inside the stage callback."
  def read(%__MODULE__{} = stage, cid) do
    with {:found, offset, size} <- StageIndex.locate(stage.index, cid),
         true <- size <= 2_097_152 and offset + size <= stage.size,
         {:ok, bytes} <- pread(stage.io, offset, size),
         :ok <- CID.verify(cid, bytes) do
      {:ok, bytes}
    else
      _ -> {:error, :staged_block_not_found}
    end
  end

  defp pread(_, _, 0), do: {:ok, <<>>}
  defp pread(io, offset, size), do: :file.pread(io, offset, size)

  defp stage(chunks, decoder, initial, consume) do
    chunks
    |> Enum.reduce_while({:ok, decoder, initial}, fn chunk, {:ok, decoder, staged} ->
      case Decoder.feed(decoder, chunk, staged, &store/2) do
        {:ok, _, _} = next -> {:cont, next}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoder, staged} ->
        with :ok <- Decoder.finish(decoder), do: consume.(staged)

      error ->
        error
    end
  catch
    :car_staging_unavailable -> {:error, :car_staging_unavailable}
  end

  defp store({:header, roots}, stage), do: {:cont, %{stage | roots: roots}}

  defp store({:block, cid, bytes}, stage) do
    case StageIndex.locate(stage.index, cid) do
      {:found, _, _} ->
        {:cont, stage}

      {:empty, slot} ->
        with :ok <- :file.pwrite(stage.io, stage.size, bytes),
             :ok <- StageIndex.put(stage.index, slot, cid, stage.size, byte_size(bytes)) do
          {:cont, %{stage | size: stage.size + byte_size(bytes), blocks: stage.blocks + 1}}
        else
          _ -> throw(:car_staging_unavailable)
        end

      _ ->
        throw(:car_staging_unavailable)
    end
  end
end
