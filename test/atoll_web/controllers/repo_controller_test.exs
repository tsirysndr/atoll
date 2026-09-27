defmodule AtollWeb.RepoControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{CAR, CID, Commit, MST, Repositories, SigningKey}
  @did "did:plc:example"
  @collection "com.example.record"
  @get "/xrpc/com.atproto.repo.getRecord"
  @list "/xrpc/com.atproto.repo.listRecords"
  @export "/xrpc/com.atproto.sync.getRepo"

  setup do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)

    operations =
      for rkey <- ["a", "B", "z", "~"],
          do: {:put, @collection <> "/" <> rkey, %{"$type" => @collection, "text" => rkey}}

    {:ok, head} = Repositories.apply_writes(@did, operations, key)
    %{key: key, head: head}
  end

  test "deprecated head and checkout endpoints mirror the current commit and full export", %{
    conn: conn,
    head: head
  } do
    assert conn |> get("/xrpc/com.atproto.sync.getHead", %{did: @did}) |> json_response(200) ==
             %{"root" => CID.to_base32(head.head)}

    full = conn |> get(@export, %{did: @did}) |> response(200)
    checkout = get(conn, "/xrpc/com.atproto.sync.getCheckout", %{did: @did})
    assert response(checkout, 200) == full
    assert get_resp_header(checkout, "content-type") == ["application/vnd.ipld.car"]

    # A supplied since parameter is ignored: checkouts are always complete.
    assert conn
           |> get("/xrpc/com.atproto.sync.getCheckout", %{did: @did, since: head.rev})
           |> response(200) == full

    assert conn
           |> get("/xrpc/com.atproto.sync.getHead", %{did: "did:plc:absentabsentabsentabsent"})
           |> json_response(400)

    {:ok, _} = Repositories.set_status(@did, :deactivated)

    assert %{"error" => "RepoDeactivated"} =
             conn |> get("/xrpc/com.atproto.sync.getHead", %{did: @did}) |> json_response(400)

    assert %{"error" => "RepoDeactivated"} =
             conn |> get("/xrpc/com.atproto.sync.getCheckout", %{did: @did}) |> json_response(400)
  end

  test "returns a current record with a string CID and optional matching CID", %{conn: conn} do
    params = %{repo: @did, collection: @collection, rkey: "a"}
    body = conn |> get(@get, params) |> json_response(200)
    assert body["uri"] == "at://#{@did}/#{@collection}/a"
    assert body["value"]["text"] == "a"
    assert {:ok, _} = CID.from_base32(body["cid"])
    assert conn |> get(@get, Map.put(params, :cid, body["cid"])) |> json_response(200) == body
    wrong = CID.create("unrelated", :dag_cbor) |> CID.to_base32()

    assert %{"error" => "RecordNotFound"} =
             conn |> get(@get, Map.put(params, :cid, wrong)) |> json_response(400)

    assert %{"error" => "RecordNotFound"} =
             conn |> get(@get, %{params | rkey: "missing"}) |> json_response(400)
  end

  test "paginates in bytewise descending order and reverses without repeating boundaries", %{
    conn: conn
  } do
    params = %{repo: @did, collection: @collection, limit: "2"}
    first = conn |> get(@list, params) |> json_response(200)
    assert texts(first) == ["~", "z"]
    second = conn |> get(@list, Map.put(params, :cursor, first["cursor"])) |> json_response(200)
    assert texts(second) == ["a", "B"]
    refute Map.has_key?(second, "cursor")
    first = conn |> get(@list, Map.put(params, :reverse, "true")) |> json_response(200)
    assert texts(first) == ["B", "a"]

    second =
      conn
      |> get(@list, Map.merge(params, %{reverse: "true", cursor: first["cursor"]}))
      |> json_response(200)

    assert texts(second) == ["z", "~"]
  end

  test "CID selects a retained version after updates and deletion", %{conn: conn, key: key} do
    params = %{repo: @did, collection: @collection, rkey: "a"}
    original = conn |> get(@get, params) |> json_response(200)
    selected = Map.put(params, :cid, original["cid"])
    path = @collection <> "/a"
    changed = %{"$type" => @collection, "text" => "changed"}
    {:ok, _} = Repositories.apply_writes(@did, [{:put, path, changed}], key)
    assert conn |> get(@get, selected) |> json_response(200) == original

    assert conn |> get(@get, params) |> json_response(200) |> get_in(["value", "text"]) ==
             "changed"

    {:ok, _} = Repositories.apply_writes(@did, [{:delete, path}], key)
    assert conn |> get(@get, selected) |> json_response(200) == original
    assert %{"error" => "RecordNotFound"} = conn |> get(@get, params) |> json_response(400)
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert %{"error" => "RepoDeactivated"} = conn |> get(@get, selected) |> json_response(400)
  end

  test "version reads reject other paths, other accounts, and unreferenced blocks", %{conn: conn} do
    params = %{repo: @did, collection: @collection, rkey: "a"}
    original = conn |> get(@get, params) |> json_response(200)

    assert %{"error" => "RecordNotFound"} =
             conn
             |> get(@get, Map.merge(params, %{rkey: "B", cid: original["cid"]}))
             |> json_response(400)

    other = "did:plc:historyother"
    {:ok, _} = Repositories.create(other, SigningKey.generate())

    assert %{"error" => "RecordNotFound"} =
             conn
             |> get(@get, Map.merge(params, %{repo: other, cid: original["cid"]}))
             |> json_response(400)

    {:ok, unused} = Atoll.Storage.put_node(%{"$type" => @collection, "text" => "unused"})

    assert %{"error" => "RecordNotFound"} =
             conn
             |> get(@get, Map.put(params, :cid, CID.to_base32(unused)))
             |> json_response(400)
  end

  test "historical reads fail closed when retained commit bytes are corrupted", %{
    conn: conn,
    key: key,
    head: head
  } do
    params = %{repo: @did, collection: @collection, rkey: "a"}
    original = conn |> get(@get, params) |> json_response(200)
    {:ok, _} = Repositories.apply_writes(@did, [{:delete, @collection <> "/a"}], key)
    import Ecto.Query

    Atoll.Repo.update_all(from(b in Atoll.Storage.Block, where: b.cid == ^head.head),
      set: [data: "corrupted"]
    )

    assert %{"error" => "InternalServerError"} =
             conn |> get(@get, Map.put(params, :cid, original["cid"])) |> json_response(500)
  end

  test "version reads authenticate only the selected path and record body", %{
    conn: conn,
    key: key
  } do
    writes =
      for i <- 1..100,
          do: {:put, @collection <> "/r#{i}", %{"$type" => @collection, "text" => "r#{i}"}}

    {:ok, old_head} = Repositories.apply_writes(@did, writes, key)
    {:ok, archive} = Repositories.export(@did)
    {:ok, %{blocks: blocks}} = CAR.decode(archive)
    {:ok, commit} = Atoll.CBOR.decode(blocks[old_head.head])

    {:ok, proof} =
      MST.Proof.fetch(commit["data"].cid, @collection <> "/r1", &Map.fetch(blocks, &1))

    {:ok, tree} = MST.load(commit["data"].cid, blocks)
    sibling = Enum.find(Map.keys(tree.blocks), &(not Map.has_key?(proof.blocks, &1)))
    assert sibling
    params = %{repo: @did, collection: @collection, rkey: "r1", cid: CID.to_base32(proof.cid)}
    original = conn |> get(@get, params) |> json_response(200)
    {:ok, _} = Repositories.apply_writes(@did, [{:delete, @collection <> "/r1"}], key)

    for cid <- [sibling, tree.records[@collection <> "/r2"]] do
      Atoll.Repo.get!(Atoll.Storage.Block, cid)
      |> Ecto.Changeset.change(data: "corrupt")
      |> Atoll.Repo.update!()
    end

    assert conn |> get(@get, params) |> json_response(200) == original

    Atoll.Repo.get!(Atoll.Storage.Block, proof.cid)
    |> Ecto.Changeset.change(data: "corrupt")
    |> Atoll.Repo.update!()

    assert conn |> get(@get, params) |> json_response(500)
  end

  test "version reads reject corrupt or missing selected tree nodes", %{
    conn: conn,
    key: key,
    head: head
  } do
    params = %{repo: @did, collection: @collection, rkey: "a"}
    original = conn |> get(@get, params) |> json_response(200)
    params = Map.put(params, :cid, original["cid"])
    {:ok, bytes} = Atoll.Storage.get_block(head.head)
    {:ok, commit} = Atoll.CBOR.decode(bytes)
    {:ok, _} = Repositories.apply_writes(@did, [{:delete, @collection <> "/a"}], key)

    damaged =
      Atoll.Repo.get!(Atoll.Storage.Block, commit["data"].cid)
      |> Ecto.Changeset.change(data: "corrupt")
      |> Atoll.Repo.update!()

    assert conn |> get(@get, params) |> json_response(500)
    Atoll.Repo.delete!(damaged)
    assert conn |> get(@get, params) |> json_response(500)
  end

  test "injected revision membership cannot authorize a record at another path", %{
    conn: conn,
    head: head
  } do
    {:ok, unused} = Atoll.Storage.put_node(%{"$type" => @collection, "text" => "unused"})
    revision = Atoll.Repo.get_by!(Atoll.Repositories.Revision, did: @did, rev: head.rev)
    revision |> Ecto.Changeset.change(blocks: [unused | revision.blocks]) |> Atoll.Repo.update!()
    params = %{repo: @did, collection: @collection, rkey: "a", cid: CID.to_base32(unused)}
    assert %{"error" => "RecordNotFound"} = conn |> get(@get, params) |> json_response(400)
  end

  test "scopes lists to repository and collection", %{conn: conn} do
    assert %{"records" => []} =
             conn
             |> get(@list, %{repo: @did, collection: "com.example.other"})
             |> json_response(200)

    assert %{"error" => "RepoNotFound"} =
             conn
             |> get(@list, %{repo: "did:plc:missing", collection: @collection})
             |> json_response(400)
  end

  test "invalid query types and values produce XRPC errors", %{conn: conn} do
    params = %{repo: @did, collection: @collection}

    for override <- [
          %{limit: "0"},
          %{limit: "101"},
          %{limit: "1.5"},
          %{limit: ["1"]},
          %{reverse: "yes"},
          %{cursor: ".."},
          %{repo: [@did]},
          %{collection: "invalid"},
          %{repo: "alice.example.test"}
        ] do
      assert %{"error" => "InvalidRequest"} =
               conn |> get(@list, Map.merge(params, override)) |> json_response(400)
    end

    for params <- [
          %{},
          %{repo: @did, collection: @collection, rkey: "bad/key"},
          %{repo: @did, collection: @collection, rkey: "a", cid: "bad"}
        ] do
      assert %{"error" => "InvalidRequest"} = conn |> get(@get, params) |> json_response(400)
    end
  end

  test "exports a signed complete CAR with the correct media type", %{
    conn: conn,
    head: head,
    key: key
  } do
    conn =
      conn |> put_req_header("accept", "application/vnd.ipld.car") |> get(@export, %{did: @did})

    assert get_resp_header(conn, "content-type") == ["application/vnd.ipld.car"]
    assert {:ok, %{roots: [root], blocks: blocks}} = CAR.decode(response(conn, 200))
    assert root == head.head
    assert {:ok, commit} = Commit.verify(blocks[root], @did, key.curve, key.public)
    assert {:ok, tree} = MST.load(commit["data"].cid, blocks)
    assert map_size(tree.records) == 4
    assert Enum.all?(tree.records, fn {_, cid} -> Map.has_key?(blocks, cid) end)
  end

  test "export errors are JSON, including malformed revisions", %{conn: conn} do
    assert %{"error" => "RepoNotFound"} =
             conn |> get(@export, %{did: "did:plc:missing"}) |> json_response(400)

    for params <- [%{}, %{did: [@did]}, %{did: @did, since: "bad"}] do
      assert %{"error" => "InvalidRequest"} = conn |> get(@export, params) |> json_response(400)
    end
  end

  defp texts(page), do: Enum.map(page["records"], & &1["value"]["text"])
end
