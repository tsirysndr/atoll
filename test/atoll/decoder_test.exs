defmodule Atoll.CBOR.DecoderTest do
  use ExUnit.Case, async: true

  alias Atoll.CBOR
  alias Atoll.CBOR.Bytes

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

  test "decodes UTF-8 text without changing its bytes" do
    assert CBOR.decode(<<0x60>>) == {:ok, ""}
    assert CBOR.decode(<<0x65, "hello">>) == {:ok, "hello"}
    assert CBOR.decode(<<0x62, 0xC3, 0xA9>>) == {:ok, "\u00E9"}
    assert CBOR.decode(<<0x63, 0x65, 0xCC, 0x81>>) == {:ok, "e\u0301"}
  end

  test "decodes byte strings into explicit wrappers" do
    assert CBOR.decode(<<0x40>>) == {:ok, %Bytes{data: <<>>}}

    assert CBOR.decode(<<0x42, 0, 255>>) ==
             {:ok, %Bytes{data: <<0, 255>>}}

    assert CBOR.decode(<<0x45, "hello">>) ==
             {:ok, %Bytes{data: "hello"}}
  end

  test "decodes string lengths at encoding boundaries" do
    for {size, text_header, bytes_header} <- [
          {23, <<0x77>>, <<0x57>>},
          {24, <<0x78, 24>>, <<0x58, 24>>},
          {255, <<0x78, 255>>, <<0x58, 255>>},
          {256, <<0x79, 1, 0>>, <<0x59, 1, 0>>},
          {65_535, <<0x79, 255, 255>>, <<0x59, 255, 255>>},
          {65_536, <<0x7A, 0, 1, 0, 0>>, <<0x5A, 0, 1, 0, 0>>}
        ] do
      data = :binary.copy("a", size)

      assert CBOR.decode(text_header <> data) == {:ok, data}
      assert CBOR.decode(bytes_header <> data) == {:ok, %Bytes{data: data}}
    end
  end

  test "rejects invalid UTF-8 in text strings" do
    for bytes <- [
          <<0x61, 255>>,
          <<0x61, 0xC3>>,
          <<0x62, 0xC0, 0x80>>
        ] do
      assert CBOR.decode(bytes) == {:error, :invalid_cbor}
    end
  end

  test "rejects truncated strings and trailing data" do
    for bytes <- [
          <<0x61>>,
          <<0x42, 0>>,
          <<0x78>>,
          <<0x59, 1>>,
          <<0x7B, 0xFFFFFFFFFFFFFFFF::64>>,
          <<0x60, 0>>,
          <<0x40, 0>>
        ] do
      assert CBOR.decode(bytes) == {:error, :invalid_cbor}
    end
  end

  test "rejects non-minimal and indefinite string lengths" do
    for bytes <- [
          <<0x78, 0>>,
          <<0x58, 0>>,
          <<0x79, 0, 24>> <> :binary.copy("a", 24),
          <<0x59, 0, 24>> <> :binary.copy("a", 24),
          <<0x7F, 0xFF>>,
          <<0x5F, 0xFF>>
        ] do
      assert CBOR.decode(bytes) == {:error, :invalid_cbor}
    end
  end
end
