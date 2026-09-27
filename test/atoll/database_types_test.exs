defmodule Atoll.DatabaseTypesTest do
  use ExUnit.Case, async: true
  alias Atoll.{BinaryArray, StringArray}

  test "binary arrays preserve arbitrary bytes, duplicates, and empty arrays" do
    adapter = Atoll.Repo.__adapter__()

    for values <- [[], [<<0, 255, 128>>, <<0, 255, 128>>, <<>>]] do
      assert {:ok, dumped} = Ecto.Type.adapter_dump(adapter, BinaryArray, values)
      assert {:ok, ^values} = Ecto.Type.adapter_load(adapter, BinaryArray, dumped)
    end

    assert :error = BinaryArray.cast([nil])
    assert :error = BinaryArray.cast([42])
  end

  test "nullable recovery arrays clear to SQL NULL instead of the JSON string null" do
    adapter = Atoll.Repo.__adapter__()

    for type <- [StringArray, BinaryArray] do
      assert {:ok, nil} = Ecto.Type.adapter_dump(adapter, type, nil)
      assert {:ok, nil} = Ecto.Type.adapter_load(adapter, type, nil)
    end

    values = ["bafyexample", "bafyother"]
    assert {:ok, dumped} = Ecto.Type.adapter_dump(adapter, StringArray, values)
    assert {:ok, ^values} = Ecto.Type.adapter_load(adapter, StringArray, dumped)
  end
end
