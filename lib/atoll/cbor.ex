defmodule Atoll.CBOR do
  @moduledoc """
  Deterministic CBOR encoding for ATProto.

  Currently supports integers, booleans, and null.
  """

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

  def encode!(_value) do
    raise ArgumentError, "unsupported CBOR value or integer outside signed 64-bit range"
  end

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
