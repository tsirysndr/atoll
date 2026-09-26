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

  test "imports and uploads into a deactivated account without exposing data or allowing record writes",
       c do
    bytes = "migration blob"
    cid = CID.create(bytes, :raw)

    value = %{
      "$type" => "com.example.record",
      "blob" => %{
        "$type" => "blob",
        "ref" => %CBOR.Link{cid: cid},
        "mimeType" => "text/plain",
        "size" => byte_size(bytes)
      }
    }

    {:ok, _} = Repositories.set_status(@did, :deactivated)
    seq = Atoll.Repositories.Events.latest_seq()
    assert response(post_upload(c, archive(c, record: value)), 200) == ""
    assert {:ok, %{status: :deactivated}} = Repositories.get_head(@did)
    assert {:ok, {:skip, _}} = Atoll.Repositories.Events.next_frame(seq)
    assert {:error, {:repo_inactive, :deactivated}} = Repositories.export(@did)
    assert {:error, {:repo_inactive, :deactivated}} = Sessions.authenticate(c.pair.access_jwt)
    auth = put_req_header(c.conn, "authorization", "Bearer " <> c.pair.access_jwt)

    assert %{"blobs" => [_]} =
             auth |> get("/xrpc/com.atproto.repo.listMissingBlobs") |> json_response(200)

    assert %{"blob" => _} =
             auth
             |> put_req_header("content-type", "text/plain")
             |> post("/xrpc/com.atproto.repo.uploadBlob", bytes)
             |> json_response(200)

    assert %{"blobs" => []} =
             auth |> get("/xrpc/com.atproto.repo.listMissingBlobs") |> json_response(200)

    assert {:error, {:repo_inactive, :deactivated}} = Atoll.Blobs.get_public(@did, cid)

    assert %{"error" => "RepoDeactivated"} =
             auth
             |> put_req_header("content-type", "application/json")
             |> post("/xrpc/com.atproto.repo.createRecord", %{
               repo: @did,
               collection: "com.example.record",
               record: %{"$type" => "com.example.record"}
             })
             |> json_response(400)

    {:ok, _} = Repositories.set_status(@did, :active)
    assert {:ok, %{bytes: ^bytes}} = Atoll.Blobs.get_public(@did, cid)
    assert {:ok, _} = Repositories.get_record(@did, @path)
  end

  test "rejects administrative restrictions before ingestion and rechecks after reading", c do
    bytes = archive(c)

    for status <- [:suspended, :takendown] do
      {:ok, _} = Repositories.set_status(@did, status)
      assert post_upload(c, bytes) |> json_response(400)
    end

    {:ok, _} = Repositories.set_status(@did, :deactivated)
    ingested = upload_conn(c, bytes) |> AtollWeb.RepoImportPlug.call([])
    refute ingested.halted
    {:ok, _} = Repositories.set_status(@did, :takendown)

    assert AtollWeb.RepoImportController.create(ingested, %{}) ==
             {:error, {:repo_inactive, :takendown}}

    assert {:ok, %{head: head}} = Repositories.get_head(@did)
    assert head == c.head.head
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

  test "staged publication is atomic, ignores extra blocks, and retries idempotently", c do
    {:ok, decoded} = CAR.decode(archive(c))
    extra = CID.create("unreachable", :raw)

    {:ok, chunks} =
      CAR.encode_stream(decoded.roots, Map.put(decoded.blocks, extra, "unreachable"))

    seq = Atoll.Repositories.Events.latest_seq()

    assert {:ok, imported} =
             Atoll.CAR.Stage.with_chunks(chunks, fn stage ->
               Repositories.import_staged(c.pair.access_jwt, stage, c.head.head)
             end)

    assert Atoll.Storage.get_block(extra) == {:error, :not_found}
    assert {:ok, [%{kind: :sync} = event]} = Atoll.Repositories.Events.list_after(seq)

    assert {:ok, ^imported} =
             Atoll.CAR.Stage.with_chunks(chunks, fn stage ->
               Repositories.import_staged(c.pair.access_jwt, stage, imported.head)
             end)

    assert Atoll.Repositories.Events.latest_seq() == event.seq
    assert {:ok, %{value: %{"text" => "imported"}}} = Repositories.get_record(@did, @path)
  end

  test "staged publication rolls back blocks, references and events when quota rejects it", c do
    prior = Application.fetch_env(:atoll, :repository_quota)

    on_exit(fn ->
      case prior do
        {:ok, config} -> Application.put_env(:atoll, :repository_quota, config)
        :error -> Application.delete_env(:atoll, :repository_quota)
      end
    end)

    Application.put_env(:atoll, :repository_quota, max_bytes: 0)
    count = Repo.aggregate(Atoll.Storage.Block, :count)
    references = Repo.aggregate(Atoll.Blobs.Reference, :count)

    record = %{
      "$type" => "com.example.record",
      "image" => %{
        "$type" => "blob",
        "ref" => %Atoll.CBOR.Link{cid: CID.create("blob", :raw)},
        "mimeType" => "image/png",
        "size" => 4
      }
    }

    bytes = archive(c, record: record)
    seq = Atoll.Repositories.Events.latest_seq()

    assert {:error, :repository_quota_exceeded} =
             Atoll.CAR.Stage.with_chunks([bytes], fn stage ->
               Repositories.import_staged(c.pair.access_jwt, stage, c.head.head)
             end)

    assert Repositories.get_head(@did) == {:ok, c.head}
    assert Repo.aggregate(Atoll.Storage.Block, :count) == count
    assert Repo.aggregate(Atoll.Blobs.Reference, :count) == references
    assert Atoll.Repositories.Events.latest_seq() == seq
  end

  test "staged migration re-signs the imported snapshot with the local repository key", c do
    previous = Application.fetch_env(:atoll, :key_encryption_key)
    Application.put_env(:atoll, :key_encryption_key, :binary.copy(<<88>>, 32))

    on_exit(fn ->
      case previous do
        {:ok, key} -> Application.put_env(:atoll, :key_encryption_key, key)
        :error -> Application.delete_env(:atoll, :key_encryption_key)
      end
    end)

    {:ok, _} = Atoll.KeyVault.store(@did, c.key)
    source = SigningKey.generate(:p256)

    Repo.insert!(%Atoll.Accounts.Profile{
      did: @did,
      handle: "migration.example.com",
      import_curve: source.curve,
      import_public_key: source.public
    })

    {:ok, _} = Repositories.set_status(@did, :deactivated)
    bytes = archive(c, key: source)
    {:ok, %{roots: [foreign]}} = CAR.decode(bytes)

    assert {:ok, imported} =
             Atoll.CAR.Stage.with_chunks([bytes], fn stage ->
               Repositories.import_staged(c.pair.access_jwt, stage, c.head.head)
             end)

    refute imported.head == foreign
    assert imported.status == :deactivated
    assert {:ok, local_bytes} = Atoll.Storage.get_block(imported.head)
    assert {:ok, _} = Commit.verify(local_bytes, @did, c.key.curve, c.key.public)
    assert Atoll.Storage.get_block(foreign) == {:error, :not_found}

    assert {:ok, ^imported} =
             Atoll.CAR.Stage.with_chunks([bytes], fn stage ->
               Repositories.import_staged(c.pair.access_jwt, stage, imported.head)
             end)
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
    bytes =
      CBOR.encode!(
        Keyword.get(opts, :record, %{"$type" => "com.example.record", "text" => "imported"})
      )

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
