defmodule Atoll.CommitTest do
  use ExUnit.Case, async: true
  alias Atoll.{CAR, CBOR, CID, Commit, MST, SigningKey, TID}
  alias Atoll.CBOR.{Bytes, Link}

  test "creates a verifiable v3 repository commit and exports its tree in CAR" do
    for curve <- [:p256, :k256] do
      key = SigningKey.generate(curve)
      {:ok, tree} = MST.new()
      {:ok, rev} = TID.next()
      assert {:ok, commit} = Commit.create("did:plc:example", tree.root, rev, key)
      assert CID.verify(commit.cid, commit.bytes) == :ok
      assert {:ok, signed} = Commit.verify(commit.bytes, "did:plc:example", curve, key.public)
      assert signed["version"] == 3
      assert signed["prev"] == nil
      assert signed["data"] == %Link{cid: tree.root}
      assert signed["rev"] == rev
      assert %Bytes{data: <<_::binary-size(64)>>} = signed["sig"]
      blocks = Map.put(tree.blocks, commit.cid, commit.bytes)
      assert {:ok, archive} = CAR.encode([commit.cid], blocks)
      assert {:ok, %{roots: [cid], blocks: decoded}} = CAR.decode(archive)
      assert {:ok, ^signed} = Commit.verify(decoded[cid], "did:plc:example", curve, key.public)
    end
  end

  test "rejects tampering, wrong identity, invalid schema and raw tree links" do
    key = SigningKey.generate()
    {:ok, tree} = MST.new()
    {:ok, rev} = TID.next()
    {:ok, commit} = Commit.create("did:plc:example", tree.root, rev, key)
    {:ok, signed} = CBOR.decode(commit.bytes)

    assert Commit.verify(commit.bytes, "did:plc:other", :k256, key.public) ==
             {:error, :invalid_commit}

    for altered <- [
          Map.put(signed, "rev", TID.encode(0)),
          Map.put(signed, "version", 2),
          Map.delete(signed, "prev"),
          Map.put(signed, "extra", true),
          Map.put(signed, "sig", %Bytes{data: <<0::512>>})
        ] do
      assert Commit.verify(CBOR.encode!(altered), "did:plc:example", :k256, key.public) ==
               {:error, :invalid_commit}
    end

    # A cryptographically valid signature cannot make an invalid schema valid.
    invalid = signed |> Map.delete("sig") |> Map.put("data", %Link{cid: CID.create("", :raw)})
    {:ok, sig} = SigningKey.sign(key, CBOR.encode!(invalid))
    bytes = CBOR.encode!(Map.put(invalid, "sig", %Bytes{data: sig}))
    assert Commit.verify(bytes, "did:plc:example", :k256, key.public) == {:error, :invalid_commit}

    for {did, root, revision} <- [
          {"bad", tree.root, rev},
          {"did:plc:example", tree.root, "bad"},
          {"did:plc:example", CID.create("", :raw), rev},
          {"did:plc:example", nil, rev}
        ] do
      assert Commit.create(did, root, revision, key) == {:error, :invalid_commit}
    end
  end
end
