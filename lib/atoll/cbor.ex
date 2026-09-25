defmodule Atoll.CBOR do
  @moduledoc """
  Deterministic CBOR encoding for ATProto.

  Currently supports integers, booleans, null, UTF-8 text, byte strings,
  arrays, maps with UTF-8 string keys, and CID links.
  """

  alias Atoll.CID
  alias Atoll.CBOR.{Bytes, Link}

  @min_integer -9_223_372_036_854_775_808
  @max_integer 9_223_372_036_854_775_807

  @spec encode!(term()) :: binary()
  def encode!(nil), do: <<0xF6>>
  def encode!(false), do: <<0xF4>>
  def encode!(true), do: <<0xF5>>

  def encode!(value)
      when is_integer(value) and value >= 0 and value <= @max_integer do
    encode_head(0, value)
  end

  def encode!(value)
      when is_integer(value) and value < 0 and value >= @min_integer do
    encode_head(1, -1 - value)
  end

  def encode!(%Bytes{data: data}) when is_binary(data) do
    encode_head(2, byte_size(data)) <> data
  end

  def encode!(value) when is_binary(value) do
    if String.valid?(value) do
      encode_head(3, byte_size(value)) <> value
    else
      raise ArgumentError, "CBOR text must be valid UTF-8"
    end
  end

  def encode!(values) when is_list(values) do
    items = Enum.map(values, &encode!/1)

    IO.iodata_to_binary([encode_head(4, length(values)), items])
  end

  def encode!(value) when is_map(value) and not is_struct(value) do
    entries =
      value
      |> Enum.map(fn
        {key, item} when is_binary(key) ->
          {encode!(key), encode!(item)}

        _ ->
          raise ArgumentError, "CBOR map keys must be UTF-8 strings"
      end)
      |> Enum.sort_by(fn {encoded_key, _encoded_value} -> encoded_key end)

    items =
      Enum.map(entries, fn {encoded_key, encoded_value} ->
        [encoded_key, encoded_value]
      end)

    IO.iodata_to_binary([encode_head(5, map_size(value)), items])
  end

  def encode!(%Link{cid: cid}) when is_binary(cid) do
    case CID.decode(cid) do
      {:ok, _fields} ->
        <<0xD8, 0x2A>> <> encode!(%Bytes{data: <<0, cid::binary>>})

      {:error, :invalid_cid} ->
        raise ArgumentError, "CBOR links must contain a valid binary CID"
    end
  end

  def encode!(_value) do
    raise ArgumentError, "unsupported CBOR value or integer outside signed 64-bit range"
  end

  @doc """
  Decodes exactly one CBOR value.

  Supports integers, booleans, null, UTF-8 text, byte strings,
  arrays, maps, and CID links. Decoding allows at most 64 nested containers.
  """
  @spec decode(binary()) :: {:ok, term()} | {:error, :invalid_cbor}
  defdelegate decode(bytes), to: Atoll.CBOR.Decoder

  defp encode_head(major, value) when value < 24 do
    <<major::3, value::5>>
  end

  defp encode_head(major, value) when value <= 0xFF do
    <<major::3, 24::5, value::8>>
  end

  defp encode_head(major, value) when value <= 0xFFFF do
    <<major::3, 25::5, value::16>>
  end

  defp encode_head(major, value) when value <= 0xFFFFFFFF do
    <<major::3, 26::5, value::32>>
  end

  defp encode_head(major, value) do
    <<major::3, 27::5, value::64>>
  end
end
