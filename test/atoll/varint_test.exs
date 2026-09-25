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
end
