defmodule Atoll.StagedSnapshotTest do
  use ExUnit.Case, async: true
  alias Atoll.{CAR, CBOR, CID, Commit, MST, SigningKey, TID}
  alias Atoll.CAR.Stage
  alias Atoll.Repositories.Snapshot
  @did "did:plc:stagedsnapshot"
  @path "com.example.record/one"

  defp fixture(record \\ %{"$type" => "com.example.record", "text" => "hello"}) do
    key = SigningKey.generate()
    bytes = CBOR.encode!(record)
    cid = CID.create(bytes, :dag_cbor)
    {:ok, tree} = MST.new(%{@path => cid})
    {:ok, rev} = TID.next()
    {:ok, commit} = Commit.create(@did, tree.root, rev, key)
    extra = CID.create("unreferenced", :raw)

    blocks =
      tree.blocks
      |> Map.put(cid, bytes)
      |> Map.put(commit.cid, commit.bytes)
      |> Map.put(extra, "unreferenced")

    %{key: key, commit: commit, blocks: blocks, record: cid, tree: tree, extra: extra}
  end

  test "staged validation matches buffered validation and exposes only reachable CIDs" do
    f = fixture()
    {:ok, archive} = CAR.encode([f.commit.cid], f.blocks)
    {:ok, expected} = Snapshot.decode(archive, @did, f.key.curve, f.key.public)

    assert :verified =
             Stage.with_chunks([archive], fn stage ->
               assert {:ok, snapshot} =
                        Snapshot.from_stage(stage, @did, f.key.curve, f.key.public)

               assert Map.take(snapshot, [:head, :data, :rev, :records]) ==
                        Map.drop(expected, [:blocks])

               assert MapSet.new(snapshot.block_cids) == MapSet.new(Map.keys(expected.blocks))
               refute f.extra in snapshot.block_cids
               refute Map.has_key?(snapshot, :blocks)

               for cid <- snapshot.block_cids,
                   do: assert(snapshot.read_block.(cid) == {:ok, f.blocks[cid]})

               :verified
             end)
  end

  test "rejects missing reachable blocks, incorrect keys, and incorrect record types" do
    f = fixture()
    other = SigningKey.generate()

    for {blocks, public} <- [
          {Map.delete(f.blocks, f.record), f.key.public},
          {Map.delete(f.blocks, f.tree.root), f.key.public},
          {f.blocks, other.public}
        ] do
      {:ok, archive} = CAR.encode([f.commit.cid], blocks)

      assert {:error, :invalid_snapshot} =
               Stage.with_chunks([archive], fn stage ->
                 Snapshot.from_stage(stage, @did, f.key.curve, public)
               end)
    end

    wrong = fixture(%{"$type" => "com.other.record"})
    {:ok, archive} = CAR.encode([wrong.commit.cid], wrong.blocks)

    assert {:error, :invalid_snapshot} =
             Stage.with_chunks([archive], fn stage ->
               Snapshot.from_stage(stage, @did, wrong.key.curve, wrong.key.public)
             end)
  end

  test "rejects future revisions, multiple roots, and oversized record bodies" do
    f = fixture()
    future = TID.encode((System.system_time(:microsecond) + 600_000_000) * 1024)
    {:ok, commit} = Commit.create(@did, f.tree.root, future, f.key)
    blocks = Map.put(f.blocks, commit.cid, commit.bytes)

    for roots <- [[commit.cid], [f.commit.cid, commit.cid]] do
      {:ok, archive} = CAR.encode(roots, blocks)

      assert {:error, :invalid_snapshot} =
               Stage.with_chunks([archive], fn stage ->
                 Snapshot.from_stage(stage, @did, f.key.curve, f.key.public)
               end)
    end

    large =
      fixture(%{"$type" => "com.example.record", "text" => String.duplicate("x", 1_000_000)})

    {:ok, archive} = CAR.encode([large.commit.cid], large.blocks)

    assert {:error, :invalid_snapshot} =
             Stage.with_chunks([archive], fn stage ->
               Snapshot.from_stage(stage, @did, large.key.curve, large.key.public)
             end)
  end
end
