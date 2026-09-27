defmodule Atoll.MSTBufferedConstructionTest do
  use ExUnit.Case, async: true
  alias Atoll.{CID, MST}

  defp budget(tree) do
    Enum.sum(for {path, cid} <- tree.records, do: byte_size(path) + byte_size(cid) + 128) +
      Enum.sum(for {cid, bytes} <- tree.blocks, do: byte_size(bytes) + byte_size(cid) + 96)
  end

  test "constructor and loader agree at the retained metadata budget boundary" do
    cid = CID.create("value", :dag_cbor)

    for count <- [0, 1, 500] do
      records =
        if count == 0, do: %{}, else: Map.new(1..count, &{"com.example.record/key#{&1}", cid})

      {:ok, tree} = MST.new(records)
      limit = budget(tree)
      assert {:ok, ^tree} = MST.new(records, max_bytes: limit)
      assert {:ok, ^tree} = MST.load(tree.root, tree.blocks, max_bytes: limit)
      assert {:error, :mst_too_large} = MST.new(records, max_bytes: limit - 1)
    end
  end

  test "mutations enforce their own output budgets without changing the original tree" do
    cid = CID.create("value", :dag_cbor)
    one = "com.example.record/one"
    two = "com.example.record/two"
    {:ok, initial} = MST.new(%{one => cid})
    {:ok, updated} = MST.put(initial, two, cid)
    assert {:ok, ^updated} = MST.put(initial, two, cid, max_bytes: budget(updated))
    assert {:error, :mst_too_large} = MST.put(initial, two, cid, max_bytes: budget(updated) - 1)
    assert MST.get(initial, two) == :error
    assert {:ok, ^initial} = MST.delete(updated, two, max_bytes: budget(initial))
    assert {:error, :mst_too_large} = MST.delete(updated, two, max_bytes: budget(initial) - 1)
    assert MST.get(updated, two) == {:ok, cid}
  end

  test "per-node entry and encoded-byte limits reject wide trees even with a generous total budget" do
    cid = CID.create("value", :dag_cbor)

    for {count, path} <- [
          {10_001, fn n -> "com.example.record/key#{n}" end},
          {7000,
           fn n ->
             "com.example.record/" <> Base.encode16(:crypto.hash(:sha512, Integer.to_string(n)))
           end}
        ] do
      records =
        Stream.iterate(0, &(&1 + 1))
        |> Stream.map(path)
        |> Stream.filter(&(MST.height(&1) == 0))
        |> Enum.take(count)
        |> Map.new(&{&1, cid})

      assert {:error, :mst_too_large} = MST.new(records, max_bytes: 64 * 1024 * 1024)
    end
  end

  test "rejects invalid records and budget settings" do
    assert {:error, :invalid_mst} = MST.new(nil)
    assert {:error, :invalid_mst} = MST.new(%{"bad" => <<0>>})

    assert {:error, :invalid_mst} =
             MST.new(%{"com.example.record/one" => CID.create("raw", :raw)})

    for limit <- [0, -1, nil, "64", 1.5] do
      assert_raise ArgumentError, fn -> MST.new(%{}, max_bytes: limit) end
    end
  end
end
