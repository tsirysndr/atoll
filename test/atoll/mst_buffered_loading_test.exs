defmodule Atoll.MSTBufferedLoadingTest do
  use ExUnit.Case, async: true
  alias Atoll.{CID, MST}

  test "materializes identical canonical trees without reading unrelated blocks or record bodies" do
    for count <- [0, 1, 200, 3000] do
      records =
        if count == 0,
          do: %{},
          else:
            Map.new(
              1..count,
              &{"com.example.record/key#{&1}", CID.create("value#{&1}", :dag_cbor)}
            )

      {:ok, tree} = MST.new(records)
      unrelated = Map.put(tree.blocks, CID.create("unrelated", :dag_cbor), "unrelated")
      assert {:ok, ^tree} = MST.load(tree.root, unrelated)
      ref = make_ref()

      reader = fn cid ->
        assert Map.has_key?(tree.blocks, cid)
        send(self(), {ref, cid})
        Map.fetch(tree.blocks, cid)
      end

      assert {:ok, ^tree} = MST.load(tree.root, reader)
      for cid <- Map.keys(tree.blocks), do: assert_received({^ref, ^cid})
      refute_received {^ref, _}
    end
  end

  test "accounts for retained nodes and expanded metadata with an exact budget boundary" do
    prefix = "com.example.record/" <> String.duplicate("a", 450)

    records =
      Map.new(1..100, &{prefix <> Integer.to_string(&1), CID.create("value#{&1}", :dag_cbor)})

    {:ok, tree} = MST.new(records)

    node_bytes =
      Enum.sum(for {cid, bytes} <- tree.blocks, do: byte_size(bytes) + byte_size(cid) + 96)

    record_bytes =
      Enum.sum(for {path, cid} <- records, do: byte_size(path) + byte_size(cid) + 128)

    limit = node_bytes + record_bytes
    assert {:ok, ^tree} = MST.load(tree.root, tree.blocks, max_bytes: limit)
    assert {:error, :mst_too_large} = MST.load(tree.root, tree.blocks, max_bytes: limit - 1)
    assert {:error, :mst_too_large} = MST.load(tree.root, tree.blocks, max_bytes: node_bytes)
  end

  test "stops reading immediately when a retained node exceeds the budget" do
    {:ok, tree} =
      MST.new(Map.new(1..500, &{"com.example.record/key#{&1}", CID.create("value", :dag_cbor)}))

    root = tree.root

    reader = fn cid ->
      assert cid == root, "must not read children after exhausting the budget"
      Map.fetch(tree.blocks, cid)
    end

    assert {:error, :mst_too_large} = MST.load(root, reader, max_bytes: 1)
  end

  test "invalid data and invalid limits cannot return a partial tree" do
    {:ok, tree} = MST.new()
    assert {:error, :invalid_mst} = MST.load(tree.root, %{})
    assert {:error, :invalid_mst} = MST.load(tree.root, %{tree.root => <<0>>})
    assert {:error, :invalid_mst} = MST.load(nil, %{})

    for limit <- [0, -1, nil, "64", 1.5] do
      assert_raise ArgumentError, fn -> MST.load(tree.root, tree.blocks, max_bytes: limit) end
    end
  end
end
