defmodule AtollWeb.RepoImportControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{CAR, CBOR, CID, Commit, MST, Repo, Repositories, SigningKey, TID}
  alias Atoll.Accounts.{Credentials, Sessions}
  @did "did:plc:httpimport"
  @route "/xrpc/com.atproto.repo.importRepo"
  @path "com.example.record/one"

  setup %{conn: conn} do
    previous = Application.fetch_env(:atoll, :session_signing_key)
    Application.put_env(:atoll, :session_signing_key, :binary.copy(<<19>>, 32))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atoll, :session_signing_key, value)
        :error -> Application.delete_env(:atoll, :session_signing_key)
      end
    end)

    key = SigningKey.generate()
    {:ok, head} = Repositories.create(@did, key)
    {:ok, _} = Credentials.create(@did, "import test password")
    {:ok, pair} = Sessions.create(@did, "import test password")
    id = rem(System.unique_integer([:positive]), 65_536)

    %{
      conn: %{conn | remote_ip: {10, 40, div(id, 256), rem(id, 256)}},
      key: key,
      head: head,
      pair: pair
    }
  end

  test "imports a signed CAR and retries idempotently with one sync event", c do
    archive = archive(c)
    seq = Atoll.Repositories.Events.latest_seq()
    result = post_upload(c, archive)
    assert response(result, 200) == ""
    assert get_resp_header(result, "cache-control") == ["no-store"]
    assert {:ok, %{value: %{"text" => "imported"}}} = Repositories.get_record(@did, @path)
    assert {:ok, [event]} = Atoll.Repositories.Events.list_after(seq)
    assert event.kind == :sync
    assert response(post_upload(c, archive), 200) == ""
    assert Atoll.Repositories.Events.latest_seq() == event.seq
  end

  test "rejects malformed, foreign and wrong-key archives without mutations", c do
    count = Repo.aggregate(Atoll.Storage.Block, :count)
    seq = Atoll.Repositories.Events.latest_seq()

    for bytes <- [
          "not a CAR",
          archive(c, did: "did:plc:foreign"),
          archive(c, key: SigningKey.generate())
        ] do
      assert %{"error" => "InvalidRequest"} = post_upload(c, bytes) |> json_response(400)
    end

    assert Repositories.get_head(@did) == {:ok, c.head}
    assert Repo.aggregate(Atoll.Storage.Block, :count) == count
    assert Atoll.Repositories.Events.latest_seq() == seq
  end

  test "rejects stale snapshots and does not overwrite writes made during ingestion", c do
    {:ok, old} = Repositories.export(@did)
    bytes = archive(c)
    ingested = upload_conn(c, bytes) |> AtollWeb.RepoImportPlug.call([])
    assert ingested.private.atoll_repo_import.head == c.head.head

    {:ok, changed} =
      Repositories.apply_writes(
        @did,
        [{:put, @path, %{"$type" => "com.example.record", "text" => "local"}}],
        c.key
      )

    assert AtollWeb.RepoImportController.create(ingested, %{}) == {:error, :invalid_swap}
    assert %{"error" => "InvalidRequest"} = post_upload(c, old) |> json_response(400)
    assert Repositories.get_head(@did) == {:ok, changed}
  end

  test "requires live access authorization before reading and rechecks after ingestion", c do
    bytes = archive(c)

    for conn <- [
          delete_req_header(upload_conn(c, bytes), "authorization"),
          put_req_header(upload_conn(c, bytes), "authorization", "Bearer " <> c.pair.refresh_jwt)
        ] do
      assert AtollWeb.RepoImportPlug.call(conn, []).status == 401
    end

    ingested = upload_conn(c, bytes) |> AtollWeb.RepoImportPlug.call([])
    {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)
    assert AtollWeb.RepoImportController.create(ingested, %{}) == {:error, :invalid_token}
    assert Repositories.get_head(@did) == {:ok, c.head}
  end

  test "requires matching length and CAR media type, bounds size, and enforces POST", c do
    bytes = archive(c)

    for change <- [
          fn conn -> delete_req_header(conn, "content-length") end,
          fn conn -> put_req_header(conn, "content-length", "1") end,
          fn conn -> put_req_header(conn, "content-type", "application/json") end,
          fn conn -> put_req_header(conn, "content-encoding", "gzip") end
        ] do
      assert upload_conn(c, bytes)
             |> change.()
             |> AtollWeb.RepoImportPlug.call([])
             |> json_response(400)
    end

    assert upload_conn(c, bytes)
           |> put_req_header("content-length", "67108865")
           |> AtollWeb.RepoImportPlug.call([])
           |> json_response(413)

    assert response(get(c.conn, @route), 405)
    assert Repositories.get_head(@did) == {:ok, c.head}
  end

  test "encoded routes share the import rate limit", c do
    for _ <- 1..10, do: Atoll.Accounts.SessionLimiter.check({:repo_import, c.conn.remote_ip}, 10)

    conn =
      c.conn
      |> put_req_header("content-type", "application/vnd.ipld.car")
      |> post("/xrpc/com.atproto.repo.%69mportRepo", "x")

    assert %{"error" => "RateLimitExceeded"} = json_response(conn, 429)
    assert [_] = get_resp_header(conn, "retry-after")
  end

  defp upload_conn(c, bytes) do
    Plug.Test.conn(:post, @route, bytes)
    |> Map.put(:remote_ip, c.conn.remote_ip)
    |> put_req_header("content-type", "application/vnd.ipld.car")
    |> put_req_header("content-length", Integer.to_string(byte_size(bytes)))
    |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
  end

  defp post_upload(c, bytes) do
    c.conn
    |> put_req_header("content-type", "application/vnd.ipld.car")
    |> put_req_header("content-length", Integer.to_string(byte_size(bytes)))
    |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
    |> post(@route, bytes)
  end

  defp archive(c, opts \\ []) do
    bytes = CBOR.encode!(%{"$type" => "com.example.record", "text" => "imported"})
    cid = CID.create(bytes, :dag_cbor)
    {:ok, tree} = MST.new(%{@path => cid})
    {:ok, rev} = TID.next(c.head.rev)

    {:ok, commit} =
      Commit.create(Keyword.get(opts, :did, @did), tree.root, rev, Keyword.get(opts, :key, c.key))

    {:ok, car} =
      CAR.encode(
        [commit.cid],
        tree.blocks |> Map.put(cid, bytes) |> Map.put(commit.cid, commit.bytes)
      )

    car
  end
end
