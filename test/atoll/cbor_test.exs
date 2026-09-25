defmodule Atoll.CBORTest do
  use ExUnit.Case, async: true

  alias Atoll.CBOR
  alias Atoll.CBOR.Bytes

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

  test "encodes empty and ASCII text" do
    assert CBOR.encode!("") == <<0x60>>
    assert CBOR.encode!("hello") == <<0x65, "hello">>
  end

  test "counts UTF-8 bytes and preserves their exact representation" do
    assert CBOR.encode!("\u00E9") == <<0x62, 0xC3, 0xA9>>
    assert CBOR.encode!("e\u0301") == <<0x63, 0x65, 0xCC, 0x81>>
  end

  test "rejects invalid UTF-8 text" do
    for value <- [<<255>>, <<0xC3>>, <<0xC0, 0x80>>] do
      assert_raise ArgumentError, "CBOR text must be valid UTF-8", fn ->
        CBOR.encode!(value)
      end
    end
  end

  test "encodes byte strings without interpreting them as text" do
    assert CBOR.encode!(%Bytes{data: <<>>}) == <<0x40>>

    assert CBOR.encode!(%Bytes{data: <<0, 255>>}) ==
             <<0x42, 0, 255>>

    assert CBOR.encode!(%Bytes{data: "hello"}) ==
             <<0x45, "hello">>
  end

  test "uses minimal length headers for text and byte strings" do
    for {size, text_header, bytes_header} <- [
          {23, <<0x77>>, <<0x57>>},
          {24, <<0x78, 24>>, <<0x58, 24>>},
          {255, <<0x78, 255>>, <<0x58, 255>>},
          {256, <<0x79, 1, 0>>, <<0x59, 1, 0>>},
          {65_535, <<0x79, 255, 255>>, <<0x59, 255, 255>>},
          {65_536, <<0x7A, 0, 1, 0, 0>>, <<0x5A, 0, 1, 0, 0>>}
        ] do
      data = :binary.copy("a", size)

      assert CBOR.encode!(data) == text_header <> data
      assert CBOR.encode!(%Bytes{data: data}) == bytes_header <> data
    end
  end

  test "rejects byte wrappers containing non-binary data" do
    for value <- [nil, 123, [1, 2]] do
      assert_raise ArgumentError, fn ->
        CBOR.encode!(%Bytes{data: value})
      end
    end
  end

  test "encodes empty arrays and maps" do
    assert CBOR.encode!([]) == <<0x80>>
    assert CBOR.encode!(%{}) == <<0xA0>>
  end

  test "encodes nested arrays while preserving element order" do
    value = [1, [false, nil], "hi", %Bytes{data: <<255>>}]

    assert CBOR.encode!(value) ==
             <<0x84, 1, 0x82, 0xF4, 0xF6, 0x62, "hi", 0x41, 255>>
  end

  test "orders map keys by encoded bytes" do
    value = %{"aa" => 1, "b" => 2, "a" => 3}

    assert CBOR.encode!(value) ==
             <<0xA3, 0x61, "a", 3, 0x61, "b", 2, 0x62, "aa", 1>>

    assert CBOR.encode!(%{"é" => 1, "z" => 2}) ==
             <<0xA2, 0x61, "z", 2, 0x62, 0xC3, 0xA9, 1>>
  end

  test "encodes nested maps, arrays, and byte strings" do
    value = %{"a" => [%{"b" => true}, %Bytes{data: <<255>>}]}

    assert CBOR.encode!(value) ==
             <<0xA1, 0x61, "a", 0x82, 0xA1, 0x61, "b", 0xF5, 0x41, 255>>
  end

  test "rejects invalid map keys and unsupported nested values" do
    for value <- [
          %{name: "hello"},
          %{1 => "hello"},
          %{<<255>> => "hello"},
          %{"nested" => %{bad: true}},
          [1, 1.5]
        ] do
      assert_raise ArgumentError, fn ->
        CBOR.encode!(value)
      end
    end
  end

  test "rejects unsupported structs" do
    assert_raise ArgumentError, fn ->
      CBOR.encode!(%URI{scheme: "https", host: "example.com"})
    end
  end

  test "uses minimal array length headers" do
    assert CBOR.encode!(List.duplicate(nil, 23)) ==
             <<0x97>> <> :binary.copy(<<0xF6>>, 23)

    assert CBOR.encode!(List.duplicate(nil, 24)) ==
             <<0x98, 24>> <> :binary.copy(<<0xF6>>, 24)
  end

  test "encoded empty map produces the known CID" do
    cid =
      %{}
      |> CBOR.encode!()
      |> Atoll.CID.create(:dag_cbor)
      |> Atoll.CID.to_base32()

    assert cid ==
             "bafyreigbtj4x7ip5legnfznufuopl4sg4knzc2cof6duas4b3q2fy6swua"
  end
end
