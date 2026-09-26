defmodule AtollWeb.SyncProofControllerTest do
  use AtollWeb.ConnCase, async: true
  alias Atoll.{CAR, CBOR, CID, Commit, Repo, Repositories, SigningKey}
  alias Atoll.CBOR.Link
  alias Atoll.Repositories.{Record, Revision}
  @did "did:plc:example"
  @collection "com.example.record"
  @record "/xrpc/com.atproto.sync.getRecord"
  @blocks "/xrpc/com.atproto.sync.getBlocks"

  setup do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)

    writes =
      for i <- 1..100, do: {:put, @collection <> "/r#{i}", %{"$type" => @collection, "n" => i}}

    {:ok, head} = Repositories.apply_writes(@did, writes, key)
    {:ok, full} = Repositories.export(@did)
    {:ok, %{blocks: all}} = CAR.decode(full)
    %{key: key, head: head, all: all}
  end

  test "serves compact signed proofs for present and absent records", %{
    conn: conn,
    key: key,
    head: head,
    all: all
  } do
    for rkey <- ["r1", "r50", "r100", "absent", "r50missing", "zz"] do
      response =
        conn
        |> put_req_header("accept", "application/vnd.ipld.car")
        |> get(@record, %{did: @did, collection: @collection, rkey: rkey})

      assert get_resp_header(response, "content-type") == ["application/vnd.ipld.car"]
      assert {:ok, %{roots: [root], blocks: blocks}} = CAR.decode(response(response, 200))
      assert root == head.head
      assert {:ok, commit} = Commit.verify(blocks[root], @did, key.curve, key.public)
      assert map_size(blocks) < map_size(all)
      # Independently walk the supplied proof; missing search-path blocks fail.
      {cid, visited} = walk(commit["data"], @collection <> "/" <> rkey, blocks, [])

      expected =
        case Repositories.get_record(@did, @collection <> "/" <> rkey) do
          {:ok, record} -> record.cid
          {:error, :not_found} -> nil
        end

      assert cid == expected
      expected_blocks = [root | visited] ++ if(cid, do: [cid], else: [])
      assert MapSet.new(Map.keys(blocks)) == MapSet.new(expected_blocks)
      if cid, do: assert(blocks[cid] == all[cid])
    end
  end

  test "empty repositories and deleted records provide absence proofs", %{conn: conn, key: key} do
    {:ok, _} = Repositories.apply_writes(@did, [{:delete, @collection <> "/r50"}], key)
    {:ok, _} = Repositories.create("did:plc:empty", SigningKey.generate())

    for {did, rkey} <- [{@did, "r50"}, {"did:plc:empty", "self"}] do
      bytes =
        conn |> get(@record, %{did: did, collection: @collection, rkey: rkey}) |> response(200)

      {:ok, %{roots: [root], blocks: blocks}} = CAR.decode(bytes)
      {:ok, commit} = CBOR.decode(blocks[root])
      assert {nil, _} = walk(commit["data"], @collection <> "/" <> rkey, blocks, [])
    end
  end

  test "reads repeated CID query keys and returns only requested blocks", %{conn: conn, all: all} do
    cids = all |> Map.keys() |> Enum.take(3)

    query =
      URI.encode_query([{"did", @did} | Enum.map(cids ++ cids, &{"cids", CID.to_base32(&1)})])

    bytes = conn |> get(@blocks <> "?" <> query) |> response(200)
    assert {:ok, %{roots: [], blocks: blocks}} = CAR.decode(bytes)
    assert blocks == Map.take(all, cids)
  end

  test "serves retained commits, tree nodes and deleted records but rejects foreign blocks", %{
    conn: conn,
    key: key,
    head: head
  } do
    {:ok, old} = Repositories.get_record(@did, @collection <> "/r1")
    {:ok, _} = Repositories.apply_writes(@did, [{:delete, @collection <> "/r1"}], key)
    {:ok, foreign} = Repositories.create("did:plc:other", SigningKey.generate())

    revision = Repo.get_by!(Revision, did: @did, rev: head.rev)

    for cid <- revision.blocks do
      bytes = conn |> get(@blocks, %{did: @did, cids: CID.to_base32(cid)}) |> response(200)
      assert {:ok, %{roots: [], blocks: blocks}} = CAR.decode(bytes)
      assert Map.keys(blocks) == [cid]
      assert :ok == CID.verify(cid, blocks[cid])
    end

    assert old.cid in revision.blocks

    for cid <- [foreign.head, CID.create("missing", :dag_cbor)] do
      query = URI.encode_query(%{did: @did, cids: CID.to_base32(cid)})

      assert %{"error" => "BlockNotFound"} =
               conn |> get(@blocks <> "?" <> query) |> json_response(400)
    end
  end

  test "does not trust injected revision membership and fails atomically for mixed requests", %{
    conn: conn,
    head: head
  } do
    {:ok, foreign} = Repositories.create("did:plc:foreign", SigningKey.generate())
    revision = Repo.get_by!(Revision, did: @did, rev: head.rev)
    revision |> Ecto.Changeset.change(blocks: [foreign.head | revision.blocks]) |> Repo.update!()

    query =
      URI.encode_query([
        {"did", @did},
        {"cids", CID.to_base32(head.head)},
        {"cids", CID.to_base32(foreign.head)}
      ])

    assert %{"error" => "BlockNotFound"} =
             conn |> get(@blocks <> "?" <> query) |> json_response(400)
  end

  test "rejects a retained revision with an inconsistent signed revision", %{
    conn: conn,
    key: key,
    head: head
  } do
    revision = Repo.get_by!(Revision, did: @did, rev: head.rev)
    {:ok, newer} = Repositories.apply_writes(@did, [{:delete, @collection <> "/r1"}], key)
    revision |> Ecto.Changeset.change(head: newer.head) |> Repo.update!()

    assert %{"error" => "InternalServerError"} =
             conn
             |> get(@blocks, %{did: @did, cids: CID.to_base32(head.head)})
             |> json_response(500)
  end

  test "rejects malformed requests and missing repos", %{conn: conn, head: head} do
    for params <- [
          %{},
          %{did: @did, cids: "bad"},
          %{did: @did, cids: List.duplicate(CID.to_base32(head.head), 101)}
        ] do
      assert %{"error" => "InvalidRequest"} = conn |> get(@blocks, params) |> json_response(400)
    end

    for params <- [
          %{},
          %{did: @did, collection: [@collection], rkey: "a"},
          %{did: @did, collection: @collection, rkey: ".."}
        ] do
      assert %{"error" => "InvalidRequest"} = conn |> get(@record, params) |> json_response(400)
    end

    assert %{"error" => "RepoNotFound"} =
             conn
             |> get(@record, %{did: "did:plc:missing", collection: @collection, rkey: "a"})
             |> json_response(400)
  end

  test "rejects a database record index inconsistent with the signed head", %{conn: conn} do
    Repo.get_by!(Record, did: @did, path: @collection <> "/r1") |> Repo.delete!()

    assert %{"error" => "InternalServerError"} =
             conn
             |> get(@record, %{did: @did, collection: @collection, rkey: "r1"})
             |> json_response(500)

    assert Repositories.export(@did) == {:error, :invalid_repository}
  end

  defp walk(nil, _, _, visited), do: {nil, visited}

  defp walk(%Link{cid: cid}, target, blocks, visited) do
    bytes = Map.fetch!(blocks, cid)
    assert CID.verify(cid, bytes) == :ok
    {:ok, node} = CBOR.decode(bytes)

    {entries, _} =
      Enum.map_reduce(node["e"], "", fn e, previous ->
        key = binary_part(previous, 0, e["p"]) <> e["k"].data
        {{key, e}, key}
      end)

    case Enum.find(entries, fn {key, _} -> key == target end) do
      {_, entry} ->
        {entry["v"].cid, [cid | visited]}

      nil ->
        left = entries |> Enum.filter(fn {key, _} -> key < target end) |> List.last()
        child = if left, do: elem(left, 1)["t"], else: node["l"]
        walk(child, target, blocks, [cid | visited])
    end
  end
end
