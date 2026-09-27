defmodule Atoll.MSTTraversalTest do
  use ExUnit.Case, async: true
  alias Atoll.{CBOR, CID, MST}
  alias Atoll.MST.{Traversal, TraversalError}
  alias Atoll.CBOR.{Bytes, Link}

  test "matches canonical construction across empty trees, intermediate levels and varied keys" do
    value = CID.create("record", :dag_cbor)

    for count <- [0, 1, 2, 7, 100, 5000] do
      keys = if count == 0, do: [], else: for(n <- 1..count, do: "com.example.record/key#{n}")
      {:ok, tree} = MST.new(Map.new(keys, &{&1, value}))
      events = Traversal.stream(tree.root, &Map.fetch(tree.blocks, &1)) |> Enum.to_list()
      nodes = for {:node, cid, bytes} <- events, do: {cid, bytes}
      records = for {:record, path, cid} <- events, do: {path, cid}
      assert Map.new(nodes) == tree.blocks
      assert length(nodes) == map_size(tree.blocks)
      assert records == Enum.sort(tree.records)
    end
  end

  test "cancellation fetches only demanded nodes and no record bodies" do
    value = CID.create("record", :dag_cbor)
    {:ok, tree} = MST.new(Map.new(1..1000, &{"com.example.record/key#{&1}", value}))
    ref = make_ref()

    stream =
      Traversal.stream(tree.root, fn cid ->
        send(self(), {ref, cid})
        Map.fetch(tree.blocks, cid)
      end)

    refute_received {^ref, _}
    assert [{:node, root, _}] = Enum.take(stream, 1)
    assert root == tree.root
    assert_received {^ref, ^root}
    refute_received {^ref, _}
  end

  test "node, record and pending-byte limits stop traversal" do
    value = CID.create("record", :dag_cbor)
    {:ok, tree} = MST.new(Map.new(1..200, &{"com.example.record/key#{&1}", value}))

    for opts <- [[max_nodes: 1], [max_records: 199], [max_pending_bytes: 1]] do
      assert_raise TraversalError, fn ->
        Traversal.stream(tree.root, &Map.fetch(tree.blocks, &1), opts) |> Enum.to_list()
      end
    end

    assert length(
             Traversal.stream(tree.root, &Map.fetch(tree.blocks, &1),
               max_nodes: map_size(tree.blocks),
               max_records: 200
             )
             |> Enum.to_list()
           ) == map_size(tree.blocks) + 200

    assert_raise ArgumentError, fn ->
      Traversal.stream(tree.root, &Map.fetch(tree.blocks, &1), max_nodes: 0)
    end
  end

  test "pending-byte budget is released as branches complete" do
    value = CID.create("record", :dag_cbor)
    {:ok, tree} = MST.new(Map.new(1..5000, &{"com.example.record/key#{&1}", value}))
    total = Enum.reduce(tree.blocks, 0, fn {_, bytes}, acc -> acc + byte_size(bytes) end)
    budget = div(total, 5)
    events = Traversal.stream(tree.root, &Map.fetch(tree.blocks, &1), max_pending_bytes: budget)
    assert Enum.count(events) == map_size(tree.blocks) + 5000
  end

  test "rejects malformed nodes, invalid compression and skipped tree levels" do
    value = CID.create("record", :dag_cbor)
    key = "com.example.record/key"
    entry = %{"p" => 0, "k" => %Bytes{data: key}, "v" => %Link{cid: value}, "t" => nil}

    for node <- [
          %{"l" => nil, "e" => [Map.put(entry, "p", 1)]},
          %{"l" => nil, "e" => [entry, entry]},
          %{"l" => nil, "e" => [Map.put(entry, "v", %Link{cid: CID.create("x", :raw)})]},
          %{"l" => nil, "e" => [], "extra" => nil},
          %{"l" => %Link{cid: value}, "e" => []}
        ] do
      {cid, bytes} = block(node)

      assert_raise TraversalError, fn ->
        Traversal.stream(cid, &Map.fetch(%{cid => bytes}, &1)) |> Enum.to_list()
      end
    end

    high = "app.bsky.feed.post/9adeb165882c"
    low = "app.bsky.feed.post/454397e440ec"
    {child, child_bytes} = block(%{"l" => nil, "e" => [%{entry | "k" => %Bytes{data: low}}]})

    {root, root_bytes} =
      block(%{"l" => %Link{cid: child}, "e" => [%{entry | "k" => %Bytes{data: high}}]})

    assert_raise TraversalError, fn ->
      Traversal.stream(root, &Map.fetch(%{root => root_bytes, child => child_bytes}, &1))
      |> Enum.to_list()
    end
  end

  test "unvisited branches must also be valid before full traversal succeeds" do
    value = CID.create("record", :dag_cbor)
    {:ok, tree} = MST.new(Map.new(1..200, &{"com.example.record/key#{&1}", value}))

    for cid <- Map.keys(tree.blocks) do
      assert_raise TraversalError, fn ->
        Traversal.stream(tree.root, &Map.fetch(Map.delete(tree.blocks, cid), &1))
        |> Enum.to_list()
      end
    end
  end

  defp block(node) do
    bytes = CBOR.encode!(node)
    {CID.create(bytes, :dag_cbor), bytes}
  end
end
