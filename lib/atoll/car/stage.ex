defmodule Atoll.CAR.Stage do
  @moduledoc """
  Request-scoped disk staging for validated CAR blocks. No public storage writes.
  The callback must finish using the stage before returning; its file is then
  closed and removed even on exceptions. Roots and the CID/offset index remain
  in memory, while record bodies stay on disk. VM/host crashes may leave
  private temporary files for operational cleanup.
  """
  alias Atoll.{CID, CAR.Decoder}
  defstruct [:io, roots: [], index: %{}, size: 0]

  def with_chunks(chunks, consume, opts \\ []) when is_function(consume, 1) do
    decoder = Decoder.new(Keyword.take(opts, [:max_bytes, :max_blocks]))
    with_file(opts, fn io -> stage(chunks, decoder, %__MODULE__{io: io}, consume) end)
  end

  @doc "Stage a stateful reader returning {:more | :ok, bytes, state} or {:error, reason, state}."
  def with_reader(source, next, consume, opts \\ []) do
    decoder = Decoder.new(Keyword.take(opts, [:max_bytes, :max_blocks]))
    with_file(opts, fn io -> read_source(source, next, decoder, %__MODULE__{io: io}, consume) end)
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

  defp with_file(opts, callback) do
    parent = Keyword.get(opts, :directory, System.tmp_dir!())

    case Atoll.CAR.StageLease.open(parent) do
      {:ok, lease, io} ->
        try do
          callback.(io)
        after
          Atoll.CAR.StageLease.close(lease)
        end

      error ->
        error
    end
  end

  @doc "Read a hash-verified staged block while inside the stage callback."
  def read(%__MODULE__{} = stage, cid) do
    with {:ok, {offset, size}} <- Map.fetch(stage.index, cid),
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
    if Map.has_key?(stage.index, cid) do
      {:cont, stage}
    else
      case :file.pwrite(stage.io, stage.size, bytes) do
        :ok ->
          {:cont,
           %{
             stage
             | index: Map.put(stage.index, cid, {stage.size, byte_size(bytes)}),
               size: stage.size + byte_size(bytes)
           }}

        _ ->
          throw(:car_staging_unavailable)
      end
    end
  end
end
