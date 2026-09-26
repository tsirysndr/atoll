defmodule AtollWeb.MissingBlobsControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Blobs, CAR, CBOR, CID, Commit, MST, Repositories, SigningKey, TID}
  alias Atoll.Accounts.{Credentials, Sessions}
  @did "did:plc:missingblobs"
  @other "did:plc:otherblobs"
  @route "/xrpc/com.atproto.repo.listMissingBlobs"

  setup %{conn: conn} do
    previous = Application.fetch_env(:atoll, :session_signing_key)
    Application.put_env(:atoll, :session_signing_key, :binary.copy(<<23>>, 32))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atoll, :session_signing_key, value)
        :error -> Application.delete_env(:atoll, :session_signing_key)
      end
    end)

    key = SigningKey.generate()
    {:ok, head} = Repositories.create(@did, key)
    {:ok, _} = Repositories.create(@other, SigningKey.generate())
    {:ok, _} = Credentials.create(@did, "missing blobs password")
    {:ok, pair} = Sessions.create(@did, "missing blobs password")
    id = rem(System.unique_integer([:positive]), 65_536)
    conn = %{conn | remote_ip: {10, 41, div(id, 256), rem(id, 256)}}
    %{conn: conn, pair: pair, head: head, key: key}
  end

  test "imported missing blobs paginate uniquely and disappear after an upload", c do
    import_records(c, [{"a", "first"}, {"b", "second"}, {"c", "first"}])
    # Globally stored bytes owned by another account do not satisfy this account's reference.
    assert {:ok, _} = Blobs.stage(@other, "first", "text/plain")
    first = query(c, %{"limit" => "1", "did" => @other}) |> json_response(200)
    second = query(c, %{"limit" => "1", "cursor" => first["cursor"]}) |> json_response(200)
    assert length(first["blobs"]) == 1
    assert length(second["blobs"]) == 1
    refute Map.has_key?(second, "cursor")
    all = first["blobs"] ++ second["blobs"]

    expected =
      for {path, bytes} <- [{"a", "first"}, {"b", "second"}] do
        %{
          "cid" => CID.to_base32(CID.create(bytes, :raw)),
          "recordUri" => "at://#{@did}/com.example.record/#{path}"
        }
      end

    assert MapSet.new(all) == MapSet.new(expected)
    assert {:ok, _} = Blobs.stage_authenticated(c.pair.access_jwt, "first", "text/plain")
    assert %{"blobs" => [remaining]} = query(c, %{}) |> json_response(200)
    assert remaining["cid"] == CID.to_base32(CID.create("second", :raw))
    {:ok, _} = Blobs.stage_authenticated(c.pair.access_jwt, "second", "text/plain")
    assert %{"blobs" => []} == query(c, %{}) |> json_response(200)
  end

  test "metadata mismatches remain missing", c do
    import_records(c, [{"a", "first"}])
    {:ok, _} = Blobs.stage(@did, "first", "application/octet-stream")
    assert %{"blobs" => [_]} = query(c, %{}) |> json_response(200)
  end

  test "requires a live session, supports deactivated accounts and prevents caching", c do
    assert json_response(get(c.conn, @route), 401)

    assert c.conn
           |> put_req_header("authorization", "Bearer " <> c.pair.refresh_jwt)
           |> get(@route)
           |> json_response(401)

    response = query(c, %{})
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert %{"blobs" => []} == json_response(response, 200)
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert %{"blobs" => []} = query(c, %{}) |> json_response(200)
    {:ok, _} = Repositories.set_status(@did, :active)
    {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)
    assert query(c, %{}) |> json_response(401)
  end

  test "validates pagination and protects encoded aliases and methods", c do
    for params <- [
          %{"limit" => "0"},
          %{"limit" => "1001"},
          %{"limit" => "no"},
          %{"cursor" => "bad"}
        ] do
      assert query(c, params) |> json_response(400)
    end

    assert post(c.conn, @route) |> response(405)
    for _ <- 1..300, do: Atoll.Accounts.SessionLimiter.check({:session, c.conn.remote_ip}, 300)
    conn = get(c.conn, "/xrpc/com.atproto.repo.%6cistMissingBlobs")
    assert conn |> json_response(429)
    assert [_] = get_resp_header(conn, "retry-after")
  end

  defp query(c, params),
    do:
      c.conn
      |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
      |> get(@route, params)

  defp import_records(c, entries) do
    {records, blocks} =
      Enum.reduce(entries, {%{}, %{}}, fn {rkey, bytes}, {records, blocks} ->
        blob = %{
          "$type" => "blob",
          "ref" => %CBOR.Link{cid: CID.create(bytes, :raw)},
          "mimeType" => "text/plain",
          "size" => byte_size(bytes)
        }

        record = CBOR.encode!(%{"$type" => "com.example.record", "blob" => blob})
        cid = CID.create(record, :dag_cbor)
        {Map.put(records, "com.example.record/" <> rkey, cid), Map.put(blocks, cid, record)}
      end)

    {:ok, tree} = MST.new(records)
    {:ok, rev} = TID.next(c.head.rev)
    {:ok, commit} = Commit.create(@did, tree.root, rev, c.key)

    {:ok, archive} =
      CAR.encode(
        [commit.cid],
        blocks |> Map.merge(tree.blocks) |> Map.put(commit.cid, commit.bytes)
      )

    assert {:ok, _} = Repositories.import_archive(@did, archive, c.head.head)
  end
end
