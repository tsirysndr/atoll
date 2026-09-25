defmodule Atoll.CBOR.DecoderTest do
  use ExUnit.Case, async: true

  alias Atoll.CBOR

  test "decodes null and booleans" do
    assert CBOR.decode(<<0xF6>>) == {:ok, nil}
    assert CBOR.decode(<<0xF4>>) == {:ok, false}
    assert CBOR.decode(<<0xF5>>) == {:ok, true}
  end

  test "decodes integers of every supported width" do
    for {hex, value} <- [
          {"00", 0},
          {"17", 23},
          {"1818", 24},
          {"190100", 256},
          {"1A00010000", 65_536},
          {"1B0000000100000000", 4_294_967_296},
          {"1B7FFFFFFFFFFFFFFF", 9_223_372_036_854_775_807},
          {"20", -1},
          {"37", -24},
          {"3818", -25},
          {"390100", -257},
          {"3A00010000", -65_537},
          {"3B0000000100000000", -4_294_967_297},
          {"3B7FFFFFFFFFFFFFFF", -9_223_372_036_854_775_808}
        ] do
      assert CBOR.decode(Base.decode16!(hex)) == {:ok, value}
    end
  end

  test "rejects non-minimal integer encodings" do
    for hex <- [
          "1817",
          "190018",
          "1A00000100",
          "1B0000000000010000",
          "3817",
          "390018",
          "3A00000100",
          "3B0000000000010000"
        ] do
      assert CBOR.decode(Base.decode16!(hex)) == {:error, :invalid_cbor}
    end
  end

  test "rejects empty input and truncated integers" do
    for hex <- ["", "18", "1901", "1A000001", "1B00000000000000"] do
      assert CBOR.decode(Base.decode16!(hex)) == {:error, :invalid_cbor}
    end
  end

  test "rejects forbidden values and integers outside the signed range" do
    for hex <- [
          "1C",
          "1F",
          "F7",
          "F818",
          "F90000",
          "FA00000000",
          "FB0000000000000000",
          "1B8000000000000000",
          "3B8000000000000000"
        ] do
      assert CBOR.decode(Base.decode16!(hex)) == {:error, :invalid_cbor}
    end
  end

  test "rejects trailing bytes after a complete value" do
    for bytes <- [<<0, 1>>, <<0xF6, 0>>, <<0x18, 24, 0xFF>>] do
      assert CBOR.decode(bytes) == {:error, :invalid_cbor}
    end
  end
end
