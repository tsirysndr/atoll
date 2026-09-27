defmodule Atoll.SnapshotBufferTest do
  use ExUnit.Case, async: true
  alias Atoll.{CAR, CBOR, CID, Commit, MST, SigningKey, TID}
  alias Atoll.Repositories.Snapshot
  @did "did:plc:snapshotbuffer"

  defp fixture(count) do
    key = SigningKey.generate()
    bytes = CBOR.encode!(%{"$type" => "com.example.record", "text" => "shared"})
    cid = CID.create(bytes, :dag_cbor)
    prefix = "com.example.record/" <> String.duplicate("a", 450)

    records =
      if count == 0, do: %{}, else: Map.new(1..count, &{prefix <> Integer.to_string(&1), cid})

    {:ok, tree} = MST.new(records)
    {:ok, rev} = TID.next()
    {:ok, commit} = Commit.create(@did, tree.root, rev, key)
    blocks = Map.put(tree.blocks, commit.cid, commit.bytes)
    blocks = if count == 0, do: blocks, else: Map.put(blocks, cid, bytes)
    extra = CID.create("unreferenced", :raw)
    {:ok, car} = CAR.encode([commit.cid], Map.put(blocks, extra, "unreferenced"))

    block_charge =
      Enum.sum(for {cid, bytes} <- blocks, do: byte_size(bytes) + byte_size(cid) + 96)

    record_charge =
      Enum.sum(for {path, cid} <- records, do: byte_size(path) + byte_size(cid) + 128)

    %{key: key, car: car, blocks: blocks, records: records, budget: block_charge + record_charge}
  end

  test "exact output accounting deduplicates blocks but charges every expanded record path" do
    for count <- [0, 1, 500] do
      f = fixture(count)

      assert {:ok, snapshot} =
               Snapshot.decode(f.car, @did, f.key.curve, f.key.public, max_buffer_bytes: f.budget)

      assert snapshot.records == f.records
      assert snapshot.blocks == f.blocks
      refute Map.has_key?(snapshot, :block_cids)
      assert {:ok, ^snapshot} = Snapshot.decode(f.car, @did, f.key.curve, f.key.public)

      assert {:error, :car_too_large} =
               Snapshot.decode(f.car, @did, f.key.curve, f.key.public,
                 max_buffer_bytes: f.budget - 1
               )
    end
  end

  test "a small compressed archive still requires budget for its expanded metadata" do
    f = fixture(500)
    assert byte_size(f.car) < div(f.budget, 2)

    assert {:error, :car_too_large} =
             Snapshot.decode(f.car, @did, f.key.curve, f.key.public,
               max_buffer_bytes: byte_size(f.car)
             )

    # Disk staging exposes bounded streams and does not materialize this buffered output.
    assert :ok =
             CAR.Stage.with_chunks([f.car], fn stage ->
               assert {:ok, snapshot} =
                        Snapshot.from_stage(stage, @did, f.key.curve, f.key.public)

               assert Enum.count(snapshot.records) == 500
               refute Map.has_key?(snapshot, :blocks)
               :ok
             end)
  end

  test "invalid budgets and signatures fail without returning partial results" do
    f = fixture(1)
    wrong = SigningKey.generate()
    assert {:error, :invalid_snapshot} = Snapshot.decode(f.car, @did, wrong.curve, wrong.public)

    for limit <- [0, -1, nil, "64", 1.5] do
      assert_raise ArgumentError, fn ->
        Snapshot.decode(f.car, @did, f.key.curve, f.key.public, max_buffer_bytes: limit)
      end
    end
  end
end
