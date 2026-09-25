defmodule Atoll.Varint do
  @moduledoc """
  Unsigned, minimally encoded multiformats varints.
  """

  @max_value 9_223_372_036_854_775_807

  @spec encode(non_neg_integer()) :: binary()
  def encode(value)
      when is_integer(value) and value >= 0 and value <= @max_value do
    do_encode(value)
  end

  def encode(_value) do
    raise ArgumentError, "expected an integer between 0 and #{@max_value}"
  end

  defp do_encode(value) when value < 128 do
    <<value>>
  end

  defp do_encode(value) do
    byte = rem(value, 128) + 128
    <<byte, do_encode(div(value, 128))::binary>>
  end

  @spec decode(binary()) ::
          {:ok, non_neg_integer(), binary()}
          | {:error, :incomplete | :overflow | :non_minimal}
  def decode(bytes) when is_binary(bytes) do
    do_decode(bytes, 0, 1, 0)
  end

  defp do_decode(_bytes, _value, _factor, 9) do
    {:error, :overflow}
  end

  defp do_decode(<<>>, _value, _factor, _count) do
    {:error, :incomplete}
  end

  defp do_decode(<<byte, rest::binary>>, value, factor, count) do
    value = value + rem(byte, 128) * factor

    cond do
      byte >= 128 ->
        do_decode(rest, value, factor * 128, count + 1)

      byte == 0 and count > 0 ->
        {:error, :non_minimal}

      true ->
        {:ok, value, rest}
    end
  end
end
