defmodule Atoll.RecordProofTest do
  use ExUnit.Case, async: true
  alias Atoll.{CAR, CBOR, CID, Commit, MST, SigningKey, TID}
  alias Atoll.CBOR.{Bytes, Link}
  alias Atoll.Repositories.RecordProof
  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"

  test "partial paths prove inclusion and absence without unrelated subtrees" do
    cid = CID.create(CBOR.encode!(%{"$type" => "com.example.record"}), :dag_cbor)
    records = Map.new(1..200, &{"com.example.record/key#{&1}", cid})
    {:ok, tree} = MST.new(records)

    for path <- Map.keys(records) ++ ["com.example.record/absent", "com.example.record/zzz"] do
      {:ok, proof} = MST.proof(tree, path)
      assert map_size(proof.blocks) < map_size(tree.blocks)
      assert {:ok, Map.get(records, path)} == MST.Proof.verify(tree.root, path, proof.blocks)

      assert {:error, :invalid_mst_proof} =
               MST.Proof.verify(tree.root, path, Map.delete(proof.blocks, tree.root))
    end

    {:ok, empty} = MST.new()
    assert {:ok, nil} = MST.Proof.verify(empty.root, "com.example.record/key", empty.blocks)
  end

  test "signed CAR proves the requested record for both signing curves" do
    for curve <- [:k256, :p256] do
      {archive, key, path, record, _} = fixture(curve)
      assert {:ok, result} = RecordProof.verify(archive, @did, path, key.curve, key.public)
      assert result.record == record
      other = SigningKey.generate(curve)

      assert {:error, :invalid_record_proof} =
               RecordProof.verify(archive, @did, path, curve, other.public)

      assert {:error, :invalid_record_proof} =
               RecordProof.verify(archive, "did:web:wrong.example.com", path, curve, key.public)

      assert {:error, :invalid_record_proof} =
               RecordProof.verify(archive, @did, "com.example.record/absent", curve, key.public)
    end
  end

  test "missing or tampered record bytes and oversized archives fail closed" do
    {archive, key, path, _, record_cid} = fixture(:k256)
    {:ok, %{roots: roots, blocks: blocks}} = CAR.decode(archive)
    {:ok, incomplete} = CAR.encode(roots, Map.delete(blocks, record_cid))

    assert {:error, :invalid_record_proof} =
             RecordProof.verify(incomplete, @did, path, key.curve, key.public)

    tampered = binary_part(archive, 0, byte_size(archive) - 1) <> <<255>>

    assert {:error, :invalid_record_proof} =
             RecordProof.verify(tampered, @did, path, key.curve, key.public)

    assert {:error, :invalid_record_proof} =
             RecordProof.verify(
               String.duplicate("x", 2_097_153),
               @did,
               path,
               key.curve,
               key.public
             )
  end

  test "rejects malformed compression, ordering, root shape, and subtree levels" do
    path = "com.example.record/key"
    value = CID.create("record", :dag_cbor)
    entry = %{"p" => 0, "k" => %Bytes{data: path}, "v" => %Link{cid: value}, "t" => nil}

    for node <- [
          %{"l" => nil, "e" => [Map.put(entry, "p", 1)]},
          %{"l" => nil, "e" => [entry, entry]},
          %{"l" => nil, "e" => [Map.put(entry, "t", 4)]},
          %{"l" => %Link{cid: value}, "e" => []},
          %{"l" => nil, "e" => [], "extra" => true}
        ] do
      {cid, bytes} = block(node)
      assert {:error, :invalid_mst_proof} = MST.Proof.verify(cid, path, %{cid => bytes})
    end

    # A subtree may not skip the mandatory intermediate level.
    high = "app.bsky.feed.post/9adeb165882c"
    low = "app.bsky.feed.post/454397e440ec"
    {child, bytes} = block(%{"l" => nil, "e" => [%{entry | "k" => %Bytes{data: low}}]})

    {root, root_bytes} =
      block(%{"l" => %Link{cid: child}, "e" => [%{entry | "k" => %Bytes{data: high}}]})

    assert {:error, :invalid_mst_proof} =
             MST.Proof.verify(root, low, %{root => root_bytes, child => bytes})
  end

  defp fixture(curve) do
    key = SigningKey.generate(curve)
    path = "com.example.record/target"
    record = %{"$type" => "com.example.record", "text" => "verified"}
    bytes = CBOR.encode!(record)
    cid = CID.create(bytes, :dag_cbor)
    records = Map.new(1..100, &{"com.example.record/key#{&1}", cid}) |> Map.put(path, cid)
    {:ok, tree} = MST.new(records)
    {:ok, proof} = MST.proof(tree, path)
    {:ok, rev} = TID.next()
    {:ok, commit} = Commit.create(@did, tree.root, rev, key)
    blocks = proof.blocks |> Map.put(cid, bytes) |> Map.put(commit.cid, commit.bytes)
    {:ok, archive} = CAR.encode([commit.cid], blocks)
    {archive, key, path, record, cid}
  end

  defp block(node) do
    bytes = CBOR.encode!(node)
    {CID.create(bytes, :dag_cbor), bytes}
  end
end
