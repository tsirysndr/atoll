defmodule Atoll.MSTEditorTest do
  use ExUnit.Case, async: true
  alias Atoll.{CID, MST}
  alias Atoll.MST.Editor

  test "partial edits reproduce canonical trees through inserts, updates and deletes" do
    for count <- [0, 1, 10, 200, 1000] do
      records = records(count)
      {:ok, tree} = MST.new(records)

      operations =
        for n <- 1..100 do
          key = "com.example.record/r#{rem(n * 37, 150)}"
          if rem(n, 3) == 0, do: {:delete, key}, else: {:put, key, cid("new#{n}")}
        end

      {_, _, _} =
        Enum.reduce(operations, {tree.root, tree.blocks, records}, fn op,
                                                                      {root, blocks, records} ->
          assert {:ok, result} = Editor.apply(root, [op], &Map.fetch(blocks, &1))
          records = apply_record(records, op)
          {:ok, canonical} = MST.new(records)
          assert result.root == canonical.root
          blocks = Map.merge(blocks, result.created)
          assert Map.take(blocks, Map.keys(canonical.blocks)) == canonical.blocks
          {result.root, blocks, records}
        end)
    end
  end

  test "batch edits invert using only fetched boundary nodes" do
    before = records(2000)
    {:ok, tree} = MST.new(before)

    operations = [
      {:delete, "com.example.record/r1"},
      {:put, "com.example.record/r2", cid("updated")},
      {:put, "com.example.record/new", cid("created")}
    ]

    assert {:ok, changed} = Editor.apply(tree.root, operations, &Map.fetch(tree.blocks, &1))
    expected = Enum.reduce(operations, before, &apply_record(&2, &1))
    {:ok, canonical} = MST.new(expected)
    assert changed.root == canonical.root

    inverse = [
      {:delete, "com.example.record/new"},
      {:put, "com.example.record/r2", before["com.example.record/r2"]},
      {:put, "com.example.record/r1", before["com.example.record/r1"]}
    ]

    assert {:ok, reverted} = Editor.apply(changed.root, inverse, &Map.fetch(canonical.blocks, &1))
    assert reverted.root == tree.root
    assert map_size(reverted.fetched) < div(map_size(canonical.blocks), 4)
    # A verifier has only this partial proof, never the complete original tree.
    assert {:ok, verified} = Editor.apply(changed.root, inverse, &Map.fetch(reverted.fetched, &1))
    assert verified.root == tree.root

    for missing <- Map.keys(reverted.fetched) do
      proof = Map.delete(reverted.fetched, missing)

      assert {:error, :invalid_mst_edit} =
               Editor.apply(changed.root, inverse, &Map.fetch(proof, &1))
    end
  end

  test "deleting root entries collapses levels and inserting high keys restores them" do
    records = records(1000)
    {:ok, tree} = MST.new(records)
    high_keys = records |> Map.keys() |> Enum.filter(&(MST.height(&1) >= 2))
    deletes = Enum.map(high_keys, &{:delete, &1})
    assert {:ok, result} = Editor.apply(tree.root, deletes, &Map.fetch(tree.blocks, &1))
    {:ok, expected} = MST.new(Map.drop(records, high_keys))
    assert result.root == expected.root
    insertions = Enum.map(high_keys, &{:put, &1, records[&1]})

    assert {:ok, restored} =
             Editor.apply(result.root, insertions, &Map.fetch(expected.blocks, &1))

    assert restored.root == tree.root
    {:ok, one} = MST.new(Map.take(records, Enum.take(high_keys, 1)))

    assert {:ok, empty} =
             Editor.apply(one.root, [{:delete, hd(high_keys)}], &Map.fetch(one.blocks, &1))

    {:ok, expected_empty} = MST.new()
    assert empty.root == expected_empty.root
  end

  test "missing or corrupt selected nodes and malformed operations fail closed" do
    {:ok, tree} = MST.new(records(100))
    op = {:put, "com.example.record/new", cid("new")}
    assert Editor.apply(tree.root, [op], fn _ -> :error end) == {:error, :invalid_mst_edit}
    assert Editor.apply(tree.root, [op], fn _ -> {:ok, "bad"} end) == {:error, :invalid_mst_edit}

    for ops <- [
          [{:delete, "bad"}],
          [{:put, "com.example.record/new", CID.create("x", :raw)}],
          [:bad],
          List.duplicate(op, 201)
        ] do
      assert Editor.apply(tree.root, ops, &Map.fetch(tree.blocks, &1)) ==
               {:error, :invalid_mst_edit}
    end

    assert Editor.apply(tree.root, [op], &Map.fetch(tree.blocks, &1), max_bytes: 1) ==
             {:error, :mst_edit_too_large}
  end

  defp records(0), do: %{}
  defp records(n), do: Map.new(1..n, &{"com.example.record/r#{&1}", cid(Integer.to_string(&1))})
  defp cid(value), do: CID.create(value, :dag_cbor)
  defp apply_record(records, {:delete, key}), do: Map.delete(records, key)
  defp apply_record(records, {:put, key, value}), do: Map.put(records, key, value)
end
