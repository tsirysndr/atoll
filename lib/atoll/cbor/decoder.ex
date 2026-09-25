defmodule Atoll.CBOR.Decoder do
  @moduledoc """
  Strict decoding of ATProto CBOR.

  Currently supports integers, booleans, null, UTF-8 text, and byte strings.
  """

  alias Atoll.CBOR.Bytes

  @max_integer 9_223_372_036_854_775_807

  @spec decode(binary()) :: {:ok, term()} | {:error, :invalid_cbor}
  def decode(bytes) when is_binary(bytes) do
    case decode_item(bytes) do
      {:ok, value, <<>>} -> {:ok, value}
      _ -> {:error, :invalid_cbor}
    end
  end

  defp decode_item(<<0xF4, rest::binary>>), do: {:ok, false, rest}
  defp decode_item(<<0xF5, rest::binary>>), do: {:ok, true, rest}
  defp decode_item(<<0xF6, rest::binary>>), do: {:ok, nil, rest}

  defp decode_item(<<major::3, info::5, rest::binary>>)
       when major in [0, 1] do
    with {:ok, argument, rest} when argument <= @max_integer <-
           decode_argument(info, rest) do
      value = if major == 0, do: argument, else: -1 - argument
      {:ok, value, rest}
    else
      _ -> {:error, :invalid_cbor}
    end
  end

  defp decode_item(<<major::3, info::5, rest::binary>>)
       when major in [2, 3] do
    with {:ok, size, rest} <- decode_argument(info, rest),
         <<data::binary-size(size), tail::binary>> <- rest do
      cond do
        major == 2 ->
          {:ok, %Bytes{data: data}, tail}

        String.valid?(data) ->
          {:ok, data, tail}

        true ->
          {:error, :invalid_cbor}
      end
    else
      _ -> {:error, :invalid_cbor}
    end
  end

  defp decode_item(_bytes), do: {:error, :invalid_cbor}

  defp decode_argument(info, rest) when info < 24 do
    {:ok, info, rest}
  end

  defp decode_argument(24, <<value::8, rest::binary>>) when value >= 24 do
    {:ok, value, rest}
  end

  defp decode_argument(25, <<value::16, rest::binary>>) when value > 0xFF do
    {:ok, value, rest}
  end

  defp decode_argument(26, <<value::32, rest::binary>>) when value > 0xFFFF do
    {:ok, value, rest}
  end

  defp decode_argument(27, <<value::64, rest::binary>>)
       when value > 0xFFFFFFFF do
    {:ok, value, rest}
  end

  defp decode_argument(_info, _rest), do: {:error, :invalid_cbor}
end
