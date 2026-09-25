defmodule Atoll.CBORTest do
  use ExUnit.Case, async: true

  alias Atoll.CBOR

  test "encodes null and booleans" do
    assert CBOR.encode!(nil) == <<0xF6>>
    assert CBOR.encode!(false) == <<0xF4>>
    assert CBOR.encode!(true) == <<0xF5>>
  end

  test "encodes nonnegative integers using the shortest representation" do
    for {value, hex} <- [
          {0, "00"},
          {23, "17"},
          {24, "1818"},
          {255, "18FF"},
          {256, "190100"},
          {65_535, "19FFFF"},
          {65_536, "1A00010000"},
          {4_294_967_295, "1AFFFFFFFF"},
          {4_294_967_296, "1B0000000100000000"},
          {9_223_372_036_854_775_807, "1B7FFFFFFFFFFFFFFF"}
        ] do
      assert CBOR.encode!(value) == Base.decode16!(hex)
    end
  end

  test "encodes negative integers using the shortest representation" do
    for {value, hex} <- [
          {-1, "20"},
          {-24, "37"},
          {-25, "3818"},
          {-256, "38FF"},
          {-257, "390100"},
          {-65_536, "39FFFF"},
          {-65_537, "3A00010000"},
          {-4_294_967_296, "3AFFFFFFFF"},
          {-4_294_967_297, "3B0000000100000000"},
          {-9_223_372_036_854_775_808, "3B7FFFFFFFFFFFFFFF"}
        ] do
      assert CBOR.encode!(value) == Base.decode16!(hex)
    end
  end

  test "rejects floats, unsupported atoms, and out-of-range integers" do
    for value <- [
          1.5,
          :unsupported,
          9_223_372_036_854_775_808,
          -9_223_372_036_854_775_809
        ] do
      assert_raise ArgumentError, fn ->
        CBOR.encode!(value)
      end
    end
  end
end
