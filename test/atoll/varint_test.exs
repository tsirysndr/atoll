defmodule Atoll.VarintTest do
  use ExUnit.Case, async: true

  alias Atoll.Varint

  test "encodes known values using the minimum number of bytes" do
    for {value, expected} <- [
          {0, <<0>>},
          {1, <<1>>},
          {127, <<127>>},
          {128, <<128, 1>>},
          {255, <<255, 1>>},
          {300, <<172, 2>>},
          {16_383, <<255, 127>>},
          {16_384, <<128, 128, 1>>}
        ] do
      assert Varint.encode(value) == expected
    end
  end

  test "encodes the largest supported value in nine bytes" do
    assert Varint.encode(9_223_372_036_854_775_807) ==
             <<255, 255, 255, 255, 255, 255, 255, 255, 127>>
  end

  test "rejects values outside the supported integer range" do
    for value <- [-1, 9_223_372_036_854_775_808, 1.5, "128", nil] do
      assert_raise ArgumentError, fn ->
        Varint.encode(value)
      end
    end
  end

  test "decodes known encodings" do
    for {bytes, expected} <- [
          {<<0>>, 0},
          {<<1>>, 1},
          {<<127>>, 127},
          {<<128, 1>>, 128},
          {<<255, 1>>, 255},
          {<<172, 2>>, 300},
          {<<255, 127>>, 16_383},
          {<<128, 128, 1>>, 16_384}
        ] do
      assert Varint.decode(bytes) == {:ok, expected, <<>>}
    end
  end

  test "preserves bytes following the varint" do
    assert Varint.decode(<<172, 2, 99, 100>>) ==
             {:ok, 300, <<99, 100>>}
  end

  test "decodes the largest supported value" do
    bytes = <<255, 255, 255, 255, 255, 255, 255, 255, 127>>

    assert Varint.decode(bytes) ==
             {:ok, 9_223_372_036_854_775_807, <<>>}
  end

  test "rejects incomplete encodings" do
    for bytes <- [<<>>, <<128>>, <<172>>] do
      assert Varint.decode(bytes) == {:error, :incomplete}
    end
  end

  test "rejects encodings requiring more than nine bytes" do
    continuation = :binary.copy(<<128>>, 9)

    assert Varint.decode(continuation) == {:error, :overflow}
    assert Varint.decode(continuation <> <<1>>) == {:error, :overflow}
  end

  test "rejects non-minimal encodings" do
    for bytes <- [<<128, 0>>, <<129, 0>>, <<128, 128, 0>>] do
      assert Varint.decode(bytes) == {:error, :non_minimal}
    end
  end
end
