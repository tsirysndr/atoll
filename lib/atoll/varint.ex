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
end
