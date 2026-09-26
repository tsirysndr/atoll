defmodule Atoll.CAR do
  @moduledoc """
  In-memory CARv1 transport for Atoll's SHA-256 CIDv1 blocks.

  This codec verifies block hashes, not repository signatures or DAG completeness.
  Empty roots, missing root blocks, and repeated blocks are accepted for partial
  archives. Repeated sections are counted toward the block limit and deduplicated.
  Encoding sorts blocks by binary CID for reproducible output.

  Limits are local resource policies, not protocol limits. Large repository
  transfers will need a streaming interface. No database writes occur here.
  """
  alias Atoll.{CBOR, CID, Varint}
  alias Atoll.CBOR.Link

  @max_bytes 64 * 1024 * 1024
  @max_header 64 * 1024
  @max_block 2 * 1024 * 1024
  @max_blocks 100_000

  @spec encode([binary()], %{binary() => binary()}) ::
          {:ok, binary()} | {:error, :invalid_car | :car_too_large}
  def encode(roots, blocks) when is_list(roots) and is_map(blocks) do
    cond do
      length(roots) > div(@max_header, 40) or map_size(blocks) > @max_blocks ->
        {:error, :car_too_large}

      not Enum.all?(roots, &valid_cid?/1) ->
        {:error, :invalid_car}

      true ->
        header = CBOR.encode!(%{"version" => 1, "roots" => Enum.map(roots, &%Link{cid: &1})})
        first = frame(header)

        blocks
        |> Enum.sort()
        |> Enum.reduce_while({:ok, [first], byte_size(first)}, fn {cid, data}, {:ok, acc, size} ->
          cond do
            not is_binary(cid) or not is_binary(data) ->
              {:halt, {:error, :invalid_car}}

            byte_size(data) + byte_size(cid) > @max_block ->
              {:halt, {:error, :car_too_large}}

            CID.verify(cid, data) != :ok ->
              {:halt, {:error, :invalid_car}}

            true ->
              section = frame(cid <> data)
              total = size + byte_size(section)

              if total > @max_bytes,
                do: {:halt, {:error, :car_too_large}},
                else: {:cont, {:ok, [section | acc], total}}
          end
        end)
        |> case do
          {:ok, parts, _size} -> {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}
          error -> error
        end
    end
  end

  def encode(_, _), do: {:error, :invalid_car}

  @spec decode(term()) ::
          {:ok, %{roots: [binary()], blocks: %{binary() => binary()}}}
          | {:error, :invalid_car | :car_too_large}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) > @max_bytes,
    do: {:error, :car_too_large}

  def decode(bytes) when is_binary(bytes) do
    with {:ok, header, rest} <- take_frame(bytes, @max_header),
         {:ok, %{"version" => 1, "roots" => roots} = fields} <- CBOR.decode(header),
         true <- map_size(fields) == 2 and is_list(roots),
         true <- Enum.all?(roots, &match?(%Link{}, &1)),
         {:ok, blocks} <- read_blocks(rest, %{}, 0) do
      {:ok, %{roots: Enum.map(roots, & &1.cid), blocks: blocks}}
    else
      {:error, :car_too_large} = error -> error
      _ -> {:error, :invalid_car}
    end
  end

  def decode(_), do: {:error, :invalid_car}

  defp read_blocks(<<>>, blocks, _count), do: {:ok, blocks}
  defp read_blocks(_, _, @max_blocks), do: {:error, :car_too_large}

  defp read_blocks(bytes, blocks, count) do
    with {:ok, <<cid::binary-size(36), data::binary>>, rest} <- take_frame(bytes, @max_block),
         :ok <- CID.verify(cid, data) do
      read_blocks(rest, Map.put(blocks, cid, data), count + 1)
    else
      {:error, :car_too_large} = error -> error
      _ -> {:error, :invalid_car}
    end
  end

  defp take_frame(bytes, limit) do
    case Varint.decode(bytes) do
      {:ok, size, _} when size > limit ->
        {:error, :car_too_large}

      {:ok, size, rest} when size > 0 and size <= byte_size(rest) ->
        <<part::binary-size(size), tail::binary>> = rest
        {:ok, part, tail}

      _ ->
        {:error, :invalid_car}
    end
  end

  defp valid_cid?(cid), do: is_binary(cid) and match?({:ok, _}, CID.decode(cid))
  defp frame(bytes), do: Varint.encode(byte_size(bytes)) <> bytes
end
