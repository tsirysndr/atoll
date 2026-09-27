defmodule Atoll.MSTPathLoadingTest do
  use ExUnit.Case, async: true
  alias Atoll.{CID, MST}

  setup do
    records =
      Map.new(1..3000, fn n ->
        {"com.example.record/key#{n}", CID.create("value#{n}", :dag_cbor)}
      end)

    {:ok, tree} = MST.new(records)
    %{tree: tree}
  end

  test "fetches exactly the canonical search path for membership and absence", %{tree: tree} do
    for path <- [
          "com.example.record/key1",
          "com.example.record/key1739",
          "com.example.record/key3000",
          "com.example.record/missing",
          "com.example.record/0",
          "com.example.record/key99999"
        ] do
      {:ok, expected} = MST.proof(tree, path)
      ref = make_ref()

      reader = fn cid ->
        assert Map.has_key?(expected.blocks, cid), "must not load a sibling subtree"
        send(self(), {ref, cid})
        Map.fetch(tree.blocks, cid)
      end

      assert MST.Proof.fetch(tree.root, path, reader) == {:ok, expected}
      assert map_size(expected.blocks) < div(map_size(tree.blocks), 10)
      for cid <- Map.keys(expected.blocks), do: assert_received({^ref, ^cid})
      refute_received {^ref, _}
    end
  end

  test "enforces an exact retained-byte budget and stops on the crossing node", %{tree: tree} do
    path = "com.example.record/key777"
    {:ok, expected} = MST.proof(tree, path)
    bytes = Enum.reduce(expected.blocks, 0, fn {_, bytes}, sum -> sum + byte_size(bytes) end)
    reader = &Map.fetch(tree.blocks, &1)
    assert MST.Proof.fetch(tree.root, path, reader, max_bytes: bytes) == {:ok, expected}

    assert MST.Proof.fetch(tree.root, path, reader, max_bytes: bytes - 1) ==
             {:error, :mst_proof_too_large}

    ref = make_ref()

    reader = fn cid ->
      send(self(), {ref, cid})
      Map.fetch(tree.blocks, cid)
    end

    assert {:error, :mst_proof_too_large} = MST.Proof.fetch(tree.root, path, reader, max_bytes: 1)
    assert_received {^ref, _}
    refute_received {^ref, _}

    for limit <- [0, -1, 1.5, nil, 64 * 1024 * 1024 + 1] do
      assert {:error, :invalid_mst_proof} =
               MST.Proof.fetch(tree.root, path, fn _ -> flunk("invalid budget must not read") end,
                 max_bytes: limit
               )
    end
  end

  test "missing or corrupt selected blocks cannot be mistaken for absence", %{tree: tree} do
    path = "com.example.record/key777"
    {:ok, proof} = MST.proof(tree, path)

    for cid <- Map.keys(proof.blocks) do
      reader = &Map.fetch(Map.delete(proof.blocks, cid), &1)
      assert {:error, :invalid_mst_proof} = MST.Proof.fetch(tree.root, path, reader)
      reader = &Map.fetch(Map.put(proof.blocks, cid, "corrupt"), &1)
      assert {:error, :invalid_mst_proof} = MST.Proof.fetch(tree.root, path, reader)
    end

    assert {:error, :invalid_mst_proof} =
             MST.Proof.fetch(tree.root, "invalid", fn _ -> flunk("invalid path must not read") end)

    assert {:error, :invalid_mst_proof} =
             MST.Proof.fetch(tree.root, path, fn _ -> {:ok, String.duplicate("x", 1_048_577)} end)
  end

  test "an empty signed tree proves absence by loading only its root" do
    {:ok, tree} = MST.new()

    assert {:ok, %{cid: nil, blocks: blocks}} =
             MST.Proof.fetch(tree.root, "com.example.record/missing", &Map.fetch(tree.blocks, &1))

    assert blocks == tree.blocks
  end
end
