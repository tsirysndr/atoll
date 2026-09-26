defmodule AtollWeb.RepositoryDiffTest do
  use AtollWeb.ConnCase, async: true
  alias Atoll.{CAR, CBOR, Commit, MST, Repo, Repositories, SigningKey, TID}
  alias Atoll.Repositories.Revision
  @did "did:web:alice.example.com"
  @collection "com.example.record"
  @route "/xrpc/com.atproto.sync.getRepo"

  setup do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)

    ops =
      for rkey <- ["unchanged", "updated", "deleted"],
          do: {:put, @collection <> "/" <> rkey, value(rkey)}

    {:ok, before} = Repositories.apply_writes(@did, ops, key)
    {:ok, full} = Repositories.export(@did)
    {:ok, prior} = CAR.decode(full)
    %{key: key, before: before, prior: prior}
  end

  test "diff plus prior blocks reconstructs the exact current signed repository", %{
    conn: conn,
    key: key,
    before: before,
    prior: prior
  } do
    {:ok, unchanged} = Repositories.get_record(@did, @collection <> "/unchanged")
    {:ok, deleted} = Repositories.get_record(@did, @collection <> "/deleted")

    {:ok, head} =
      Repositories.apply_writes(
        @did,
        [
          {:put, @collection <> "/updated", value("new")},
          {:put, @collection <> "/added", value("added")},
          {:delete, @collection <> "/deleted"}
        ],
        key
      )

    bytes =
      conn
      |> put_req_header("accept", "application/vnd.ipld.car")
      |> get(@route, %{did: @did, since: before.rev})
      |> response(200)

    assert {:ok, %{roots: [root], blocks: delta}} = CAR.decode(bytes)
    assert root == head.head
    refute Map.has_key?(delta, unchanged.cid)
    refute Map.has_key?(delta, deleted.cid)
    assert {:ok, commit} = Commit.verify(delta[root], @did, key.curve, key.public)
    assert {:ok, tree} = MST.load(commit["data"].cid, Map.merge(prior.blocks, delta))
    refute Map.has_key?(tree.records, @collection <> "/deleted")
    assert map_size(tree.records) == 3
    {:ok, full} = Repositories.export(@did)
    {:ok, current} = CAR.decode(full)

    assert delta ==
             Map.put(Map.drop(current.blocks, Map.keys(prior.blocks)), root, current.blocks[root])

    for {path, cid} <- tree.records do
      assert {:ok, %{cid: ^cid}} = Repositories.get_record(@did, path)
    end
  end

  test "same revision exports only its commit and unknown revisions return full snapshots", %{
    conn: conn,
    before: head,
    prior: prior
  } do
    bytes = conn |> get(@route, %{did: @did, since: head.rev}) |> response(200)
    assert {:ok, %{roots: [root], blocks: blocks}} = CAR.decode(bytes)
    assert blocks == Map.take(prior.blocks, [head.head])
    assert root == head.head
    bytes = conn |> get(@route, %{did: @did, since: TID.encode(0)}) |> response(200)
    assert CAR.decode(bytes) == {:ok, prior}
  end

  test "revision lookup is repository scoped and failed writes do not leave history", %{
    before: head,
    key: key,
    prior: prior
  } do
    count = Repo.aggregate(Revision, :count)

    assert Repositories.apply_writes(
             @did,
             [{:create, @collection <> "/unchanged", value("bad")}],
             key
           ) == {:error, :record_exists}

    assert Repo.aggregate(Revision, :count) == count
    other = "did:web:other.example.com"
    {:ok, _} = Repositories.create(other, SigningKey.generate())
    {:ok, other_full} = Repositories.export(other)
    assert Repositories.export(other, head.rev) == {:ok, other_full}
    assert {:ok, bytes} = Repositories.export(@did)
    assert CAR.decode(bytes) == {:ok, prior}
  end

  test "imported revisions also support subsequent incremental exports", %{
    before: head,
    key: key,
    prior: prior
  } do
    bytes = CBOR.encode!(value("imported"))
    cid = Atoll.CID.create(bytes, :dag_cbor)
    {:ok, tree} = MST.new(%{(@collection <> "/imported") => cid})
    {:ok, rev} = TID.next(head.rev)
    {:ok, commit} = Commit.create(@did, tree.root, rev, key)
    blocks = tree.blocks |> Map.put(cid, bytes) |> Map.put(commit.cid, commit.bytes)
    {:ok, car} = CAR.encode([commit.cid], blocks)
    {:ok, imported} = Repositories.import_archive(@did, car, head.head)
    assert Repo.get_by!(Revision, did: @did, rev: rev).head == imported.head
    {:ok, delta} = Repositories.export(@did, head.rev)
    {:ok, diff} = CAR.decode(delta)
    assert {:ok, loaded} = MST.load(tree.root, Map.merge(prior.blocks, diff.blocks))
    assert loaded.records == tree.records
    {:ok, same} = Repositories.export(@did, rev)
    assert {:ok, %{blocks: same_blocks}} = CAR.decode(same)
    assert Map.keys(same_blocks) == [commit.cid]
  end

  defp value(text), do: %{"$type" => @collection, "text" => text}
end
