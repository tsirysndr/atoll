defmodule Atoll.CAR.Decoder do
  @moduledoc """
  Incremental CARv1 validation with one bounded section buffered at a time.
  Emits {:header, roots} and {:block, cid, bytes} to a synchronous consumer.
  This validates framing and hashes, not repository authenticity or completeness.
  Consumers must stage output until finish/1 succeeds and repository checks pass.
  """
  alias Atoll.{CBOR, CID, Varint}
  alias Atoll.CBOR.Link

  defstruct header?: false,
            buffer: <<>>,
            need: nil,
            parts: [],
            buffered: 0,
            total: 0,
            blocks: 0,
            max_bytes: 1_073_741_824,
            max_blocks: 1_000_000

  def new(opts \\ []) do
    bytes = Keyword.get(opts, :max_bytes, 1_073_741_824)
    blocks = Keyword.get(opts, :max_blocks, 1_000_000)

    unless is_integer(bytes) and bytes in 1..1_099_511_627_776 and
             is_integer(blocks) and blocks in 1..1_000_000,
           do: raise(ArgumentError, "invalid CAR decoder limits")

    %__MODULE__{max_bytes: bytes, max_blocks: blocks}
  end

  @doc "The consumer returns {:cont, accumulator} or {:halt, accumulator}; halt cancels the remaining input."
  def feed(%__MODULE__{} = state, chunk, acc, consume)
      when is_binary(chunk) and is_function(consume, 2) do
    if state.total + byte_size(chunk) <= state.max_bytes,
      do: parse(%{state | total: state.total + byte_size(chunk)}, chunk, acc, consume),
      else: {:error, :car_too_large}
  end

  def finish(%__MODULE__{header?: true, need: nil, buffer: <<>>}), do: :ok
  def finish(%__MODULE__{}), do: {:error, :invalid_car}

  defp parse(state, <<>>, acc, _), do: {:ok, state, acc}

  defp parse(%{need: nil} = state, <<byte, rest::binary>>, acc, consume) do
    prefix = state.buffer <> <<byte>>

    case Varint.decode(prefix) do
      {:ok, size, <<>>} when size > 0 ->
        limit = if state.header?, do: 2_097_152, else: 65_536

        cond do
          size > limit -> {:error, :car_too_large}
          state.header? and state.blocks >= state.max_blocks -> {:error, :car_too_large}
          true -> parse(%{state | buffer: <<>>, need: size}, rest, acc, consume)
        end

      {:error, :incomplete} ->
        parse(%{state | buffer: prefix}, rest, acc, consume)

      _ ->
        {:error, :invalid_car}
    end
  end

  defp parse(state, chunk, acc, consume) do
    size = min(state.need - state.buffered, min(byte_size(chunk), 4096 - byte_size(state.buffer)))
    <<part::binary-size(size), rest::binary>> = chunk
    bytes = state.buffer <> part

    buffered = state.buffered + size

    if buffered == state.need do
      section_bytes = IO.iodata_to_binary(Enum.reverse([bytes | state.parts]))

      with {:ok, event} <- section(state.header?, section_bytes) do
        next = %{
          state
          | header?: true,
            buffer: <<>>,
            need: nil,
            parts: [],
            buffered: 0,
            blocks: state.blocks + if(state.header?, do: 1, else: 0)
        }

        case consume.(event, acc) do
          {:cont, acc} -> parse(next, rest, acc, consume)
          {:halt, acc} -> {:halt, acc}
        end
      end
    else
      next =
        if byte_size(bytes) == 4096 do
          %{state | buffer: <<>>, parts: [:binary.copy(bytes) | state.parts], buffered: buffered}
        else
          %{state | buffer: :binary.copy(bytes), buffered: buffered}
        end

      parse(next, rest, acc, consume)
    end
  end

  defp section(false, bytes) do
    with {:ok, %{"version" => 1, "roots" => roots} = header} <- CBOR.decode(bytes),
         true <- map_size(header) == 2 and is_list(roots),
         true <-
           Enum.all?(roots, fn
             %Link{cid: cid} -> match?({:ok, _}, CID.decode(cid))
             _ -> false
           end) do
      {:ok, {:header, Enum.map(roots, & &1.cid)}}
    else
      _ -> {:error, :invalid_car}
    end
  end

  defp section(true, <<cid::binary-size(36), bytes::binary>>) do
    case CID.verify(cid, bytes) do
      :ok -> {:ok, {:block, cid, bytes}}
      _ -> {:error, :invalid_car}
    end
  end

  defp section(_, _), do: {:error, :invalid_car}
end
