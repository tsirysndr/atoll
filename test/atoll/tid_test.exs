defmodule Atoll.TIDTest do
  use ExUnit.Case, async: true
  alias Atoll.TID

  test "encodes sortable fixed-width values and accepts specification examples" do
    assert TID.encode(0) == "2222222222222"

    for value <- ["3jzfcijpj2z2a", "7777777777777", "3zzzzzzzzzzzz", "2222222222222"] do
      assert {:ok, number} = TID.decode(value)
      assert TID.encode(number) == value
    end

    for value <- ["3JZFCIJPJ2Z2A", "0000000000000", "zzzzzzzzzzzzz", "222", nil],
        do: refute(TID.valid?(value))
  end

  test "generates increasing revisions across equal and regressing clocks" do
    assert {:ok, first} = TID.next(nil, now: 1000, clock: 4)
    assert {:ok, second} = TID.next(first, now: 1000, clock: 4)
    assert {:ok, third} = TID.next(second, now: 999, clock: 1)
    assert first < second and second < third
    assert TID.decode(first) == {:ok, 1_024_004}
    assert TID.next("bad") == {:error, :invalid_tid}
    assert TID.next(nil, clock: 1024) == {:error, :invalid_tid}
  end
end
