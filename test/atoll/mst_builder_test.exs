defmodule Atoll.MSTBuilderTest do
  use ExUnit.Case, async: true
  alias Atoll.{CID, MST}
  alias Atoll.MST.Builder

  setup do
    blocks = start_supervised!({Agent, fn -> %{} end})
    writer = fn cid, bytes -> Agent.update(blocks, &Map.put(&1, cid, bytes)) end
    %{blocks: blocks, writer: writer}
  end

  test "sorted construction matches canonical roots and every block across tree sizes", c do
    for count <- [0, 1, 2, 7, 100, 5000] do
      entries = entries(count)
      {:ok, expected} = MST.new(Map.new(entries))
      Agent.update(c.blocks, fn _ -> %{} end)
      assert {:ok, root} = Builder.build(Stream.map(entries, & &1), c.writer)
      assert root == expected.root
      assert Agent.get(c.blocks, & &1) == expected.blocks

      actual =
        MST.Traversal.stream(root, &Map.fetch(expected.blocks, &1))
        |> Enum.flat_map(fn
          {:record, path, cid} -> [{path, cid}]
          _ -> []
        end)

      assert actual == entries
    end
  end

  test "construction handles changing tree height, deletion and empty intermediate levels", c do
    all = entries(2000)
    high = Enum.max_by(all, fn {path, _} -> MST.height(path) end)
    assert MST.height(elem(high, 0)) >= 3
    variants = [[high], Enum.take(all, 30) ++ [high], Enum.reject(all, &(&1 == high)), all]

    for entries <- variants do
      entries = entries |> Enum.uniq() |> Enum.sort()
      {:ok, expected} = MST.new(Map.new(entries))
      Agent.update(c.blocks, fn _ -> %{} end)
      assert Builder.build(entries, c.writer) == {:ok, expected.root}
      assert Agent.get(c.blocks, & &1) == expected.blocks
    end
  end

  test "rejects invalid entries, unsorted keys and duplicate paths", c do
    [{path, cid} = first, second] = entries(2)

    for entries <- [
          [second, first],
          [first, first],
          [{"bad", cid}],
          [{path, CID.create("raw", :raw)}],
          [:bad]
        ] do
      assert Builder.build(entries, c.writer) == {:error, :invalid_mst}
    end
  end

  test "record, node and pending metadata limits stop construction", c do
    items = entries(100)
    assert Builder.build(items, c.writer, max_records: 99) == {:error, :mst_too_large}
    assert Builder.build(items, c.writer, max_nodes: 1) == {:error, :mst_too_large}
    [{path, _} = first | _] = items
    charge = byte_size(path) + 128
    assert {:ok, _} = Builder.build([first], c.writer, max_pending_bytes: charge)

    assert Builder.build([first], c.writer, max_pending_bytes: charge - 1) ==
             {:error, :mst_too_large}

    assert_raise ArgumentError, fn -> Builder.build([], c.writer, max_nodes: 0) end
  end

  test "completed branches release their pending metadata budget", c do
    items = entries(5000)
    assert Enum.reduce(items, 0, fn {path, _}, n -> n + byte_size(path) + 128 end) > 16_384
    assert {:ok, root} = Builder.build(items, c.writer, max_pending_bytes: 16_384)
    {:ok, expected} = MST.new(Map.new(items))
    assert root == expected.root
  end

  test "oversized flat nodes are rejected before publication", c do
    cid = CID.create("record", :dag_cbor)

    flat =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&"com.example.record/r#{&1}")
      |> Stream.filter(&(MST.height(&1) == 0))
      |> Enum.take(10_001)
      |> Enum.sort()
      |> Enum.map(&{&1, cid})

    assert Builder.build(flat, c.writer) == {:error, :mst_too_large}
    assert Agent.get(c.blocks, & &1) == %{}

    wide =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(fn n ->
        "com.example.record/" <> Base.encode16(:crypto.hash(:sha512, Integer.to_string(n)))
      end)
      |> Stream.filter(&(MST.height(&1) == 0))
      |> Enum.take(7000)
      |> Enum.sort()
      |> Enum.map(&{&1, cid})

    assert Builder.build(wide, c.writer) == {:error, :mst_too_large}
    assert Agent.get(c.blocks, & &1) == %{}
  end

  test "writer failures stop input consumption without pretending earlier writes were atomic" do
    owner = self()

    source =
      Stream.map(entries(100), fn entry ->
        send(owner, :input)
        entry
      end)

    writer = fn _, _ ->
      send(owner, :write)
      {:error, :disk_full}
    end

    assert Builder.build(source, writer) == {:error, :mst_write_failed}
    assert_receive :write
    refute_receive :write
    consumed = drain_inputs(0)
    assert consumed < 100
  end

  defp drain_inputs(n) do
    receive do
      :input -> drain_inputs(n + 1)
    after
      0 -> n
    end
  end

  defp entries(0), do: []

  defp entries(n),
    do:
      Enum.sort(
        for i <- 1..n,
            do: {"com.example.record/r#{i}", CID.create(Integer.to_string(i), :dag_cbor)}
      )
end
