defmodule Atoll.MSTTest do
  use ExUnit.Case, async: true
  alias Atoll.{CBOR, CID, MST}
  alias Atoll.CBOR.{Bytes, Link}

  # Expected roots from bluesky-social/atproto packages/repo/tests/mst.test.ts.
  # https://github.com/bluesky-social/atproto/blob/main/packages/repo/tests/mst.test.ts
  @value "bafyreie5cvv4h45feadgeuwhbcutmh6t2ceseocckahdoe6uat64zmz454"

  test "matches reference root CIDs including empty intermediate layers" do
    {:ok, cid} = CID.from_base32(@value)

    for {keys, expected} <- [
          {[], "bafyreie5737gdxlw5i64vzichcalba3z2v5n6icifvx5xytvske7mr3hpm"},
          {["3jqfcqzm3fo2j"], "bafyreibj4lsc3aqnrvphp5xmrnfoorvru4wynt6lwidqbm2623a6tatzdu"},
          {["3jqfcqzm3fx2j"], "bafyreih7wfei65pxzhauoibu3ls7jgmkju4bspy4t2ha2qdjnzqvoy33ai"},
          {["3jqfcqzm3fp2j", "3jqfcqzm3fr2j", "3jqfcqzm3fs2j", "3jqfcqzm3ft2j", "3jqfcqzm4fc2j"],
           "bafyreicmahysq4n6wfuxo522m6dpiy7z7qzym3dzs756t5n7nfdgccwq7m"},
          {["3jqfcqzm3ft2j", "3jqfcqzm3fz2j", "3jqfcqzm3fx2j"],
           "bafyreiavxaxdz7o7rbvr3zg2liox2yww46t7g6hkehx4i4h3lwudly7dhy"}
        ] do
      records = Map.new(keys, &{"com.example.record/" <> &1, cid})
      assert {:ok, tree} = MST.new(records)
      assert CID.to_base32(tree.root) == expected
      assert {:ok, loaded} = MST.load(tree.root, tree.blocks)
      assert loaded.records == records
    end
  end

  test "mutation history does not affect the root and deletion prunes layers" do
    {:ok, cid} = CID.from_base32(@value)
    {:ok, tree} = MST.new()
    a = "com.example.record/3jqfcqzm3ft2j"
    b = "com.example.record/3jqfcqzm3fx2j"
    c = "com.example.record/3jqfcqzm3fz2j"
    {:ok, tree} = MST.put(tree, a, cid)
    {:ok, tree} = MST.put(tree, c, cid)
    initial = tree.root
    {:ok, tree} = MST.put(tree, b, cid)
    assert MST.get(tree, b) == {:ok, cid}
    {:ok, tree} = MST.delete(tree, b)
    assert tree.root == initial
    assert CID.to_base32(initial) == "bafyreidfcktqnfmykz2ps3dbul35pepleq7kvv526g47xahuz3rqtptmky"
  end

  test "matches specification key heights" do
    for {key, height} <- [
          {"2653ae71", 0},
          {"blue", 1},
          {"app.bsky.feed.post/454397e440ec", 4},
          {"app.bsky.feed.post/9adeb165882c", 8}
        ] do
      assert MST.height(key) == height
    end
  end

  test "rejects invalid paths, missing blocks, corrupted blocks, and noncanonical nodes" do
    {:ok, cid} = CID.from_base32(@value)
    assert MST.new(%{"bad" => cid}) == {:error, :invalid_mst}
    {:ok, tree} = MST.new(%{"com.example.record/self" => cid})
    assert MST.load(tree.root, %{}) == {:error, :invalid_mst}
    assert MST.load(tree.root, %{tree.root => <<0>>}) == {:error, :invalid_mst}

    node = %{
      "l" => nil,
      "e" => [%{"p" => 0, "k" => %Bytes{data: "bad"}, "v" => %Link{cid: cid}, "t" => nil}]
    }

    bytes = CBOR.encode!(node)
    root = CID.create(bytes, :dag_cbor)
    assert MST.load(root, %{root => bytes}) == {:error, :invalid_mst}
  end
end
