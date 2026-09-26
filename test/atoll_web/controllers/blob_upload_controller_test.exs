defmodule AtollWeb.BlobUploadControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Blobs, CID, Repo, Repositories, SigningKey, Storage}
  alias Atoll.Accounts.{Credentials, Sessions}
  alias Atoll.Blobs.Blob
  @did "did:plc:upload"
  @upload "/xrpc/com.atproto.repo.uploadBlob"

  setup %{conn: conn} do
    previous =
      for key <- [:session_signing_key, :blob_storage, :blob_quota],
          do: {key, Application.fetch_env(:atoll, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    Application.put_env(:atoll, :session_signing_key, :binary.copy(<<13>>, 32))
    Application.put_env(:atoll, :blob_storage, backend: :postgres)
    Application.put_env(:atoll, :blob_quota, max_bytes: 20_000_000, max_count: 100)
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, _} = Credentials.create(@did, "blob upload password")
    {:ok, pair} = Sessions.create(@did, "blob upload password")
    id = rem(System.unique_integer([:positive]), 65_536)
    conn = %{conn | remote_ip: {10, 20, div(id, 256), rem(id, 256)}}
    %{conn: conn, pair: pair, key: key}
  end

  test "uploads raw JSON and binary bytes without parsing, then serves only referenced blobs",
       c do
    for bytes <- ["{not JSON", <<0, 255, 128>>, ""] do
      result = upload(c.conn, c.pair.access_jwt, bytes, "application/json")
      assert get_resp_header(result, "cache-control") == ["no-store"]
      blob = json_response(result, 200)["blob"]
      cid = CID.create(bytes, :raw)
      assert blob["ref"]["$link"] == CID.to_base32(cid)
      assert blob["size"] == byte_size(bytes)
      assert Blobs.get_public(@did, cid) == {:error, :blob_not_found}
      assert {:ok, %{bytes: ^bytes}} = Blobs.get_staged(@did, cid)
      path = "com.example.record/" <> CID.to_base32(cid)

      {:ok, _} =
        Repositories.apply_writes(
          @did,
          [{:put, path, %{"$type" => "com.example.record", "blob" => blob}}],
          c.key
        )

      assert {:ok, %{bytes: ^bytes}} = Blobs.get_public(@did, cid)
    end
  end

  test "enforces the byte limit while reading, with or without Content-Length", c do
    max = String.duplicate("x", 5 * 1024 * 1024)

    assert upload(c.conn, c.pair.access_jwt, max)
           |> json_response(200)
           |> get_in(["blob", "size"]) == byte_size(max)

    assert %{"error" => "BlobTooLarge"} =
             upload(c.conn, c.pair.access_jwt, max <> "x") |> json_response(413)

    conn = put_req_header(c.conn, "content-length", Integer.to_string(byte_size(max) + 1))

    assert %{"error" => "BlobTooLarge"} =
             upload(conn, c.pair.access_jwt, "x") |> json_response(413)

    assert Repo.aggregate(Blob, :count) == 1
  end

  test "rejects invalid metadata, compression, length mismatch and wrong method", c do
    for {header, value} <- [
          {"content-encoding", "gzip"},
          {"content-length", "2"},
          {"content-length", "-1"}
        ] do
      assert %{"error" => "InvalidRequest"} =
               c.conn
               |> put_req_header(header, value)
               |> upload(c.pair.access_jwt, "x")
               |> json_response(400)
    end

    assert %{"error" => "InvalidRequest"} =
             upload(c.conn, c.pair.access_jwt, "x", "*/*") |> json_response(400)

    assert response(get(c.conn, @upload), 405)
    assert Repo.aggregate(Blob, :count) == 0
  end

  test "authenticates before reading and refuses refresh, revoked, and suspended sessions", c do
    anonymous =
      c.conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post(@upload, String.duplicate("x", 5 * 1024 * 1024 + 1))

    assert %{"error" => "AuthRequired"} = json_response(anonymous, 401)

    assert %{"error" => "InvalidToken"} =
             upload(c.conn, c.pair.refresh_jwt, "x") |> json_response(401)

    {:ok, _} = Repositories.set_status(@did, :suspended)

    assert %{"error" => "RepoSuspended"} =
             upload(c.conn, c.pair.access_jwt, "x") |> json_response(400)

    {:ok, _} = Repositories.set_status(@did, :active)
    {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)

    assert %{"error" => "InvalidToken"} =
             upload(c.conn, c.pair.access_jwt, "x") |> json_response(401)

    refute Repo.exists?(Blob)
  end

  test "rechecks revocation between reading the body and staging", c do
    conn =
      Plug.Test.conn(:post, @upload, "x")
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
      |> AtollWeb.BlobUploadPlug.call([])

    refute conn.halted
    {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)
    assert AtollWeb.BlobController.upload(conn, %{}) == {:error, :invalid_token}
    refute Repo.exists?(Blob)
    assert Storage.get_block(CID.create("x", :raw)) == {:error, :not_found}
  end

  test "ignores account parameters and counts uploads toward the account quota", c do
    Application.put_env(:atoll, :blob_quota, max_bytes: 1, max_count: 1)

    conn =
      c.conn
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)

    blob =
      post(conn, @upload <> "?did=did:plc:someoneelse", "x")
      |> json_response(200)
      |> Map.fetch!("blob")

    assert Repo.get_by!(Blob, cid: CID.create("x", :raw)).did == @did

    assert upload(c.conn, c.pair.access_jwt, "x", "text/plain") |> json_response(200) == %{
             "blob" => blob
           }

    assert %{"error" => "BlobQuotaExceeded"} =
             upload(c.conn, c.pair.access_jwt, "y") |> json_response(400)
  end

  test "writes through S3 and maps storage errors without creating ownership", c do
    pid = self()

    request =
      Req.new(
        plug: fn conn ->
          {:ok, "s3 bytes", conn} = Plug.Conn.read_body(conn)
          send(pid, :s3_put)
          Plug.Conn.send_resp(conn, 200, "")
        end
      )

    config = [
      endpoint: "https://objects.example.com",
      bucket: "atoll-test",
      access_key_id: "test",
      secret_access_key: "test-secret",
      request: request
    ]

    Application.put_env(:atoll, :blob_storage, backend: :s3, s3: config)
    assert upload(c.conn, c.pair.access_jwt, "s3 bytes") |> json_response(200)
    assert_received :s3_put
    assert Repo.get_by!(Blob, cid: CID.create("s3 bytes", :raw)).backend == :s3
    assert Storage.get_block(CID.create("s3 bytes", :raw)) == {:error, :not_found}
    failed = Req.new(plug: fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

    Application.put_env(:atoll, :blob_storage,
      backend: :s3,
      s3: Keyword.put(config, :request, failed)
    )

    assert %{"error" => "ServiceUnavailable"} =
             upload(c.conn, c.pair.access_jwt, "failed") |> json_response(503)

    assert Repo.aggregate(Blob, :count) == 1
  end

  test "rate limits encoded route spellings too", c do
    for _ <- 1..60,
        do:
          assert(:ok == Atoll.Accounts.SessionLimiter.check({:blob_upload, c.conn.remote_ip}, 60))

    conn =
      c.conn
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
      |> post("/xrpc/com.atproto.repo.%75ploadBlob", "x")

    assert %{"error" => "RateLimitExceeded"} = json_response(conn, 429)
    assert [_] = get_resp_header(conn, "retry-after")
  end

  @tag :minio
  test "authenticated HTTP upload and public download round trip through real MinIO", c do
    endpoint = System.fetch_env!("ATOLL_MINIO_TEST_ENDPOINT")
    assert %URI{scheme: "http", host: "127.0.0.1"} = URI.parse(endpoint)
    bucket = "atoll-upload-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    credentials = [
      access_key_id: "atoll-test",
      secret_access_key: "atoll-minio-test-only",
      region: "us-east-1",
      service: "s3"
    ]

    assert {:ok, %{status: 200}} =
             Req.put(endpoint <> "/" <> bucket, body: "", aws_sigv4: credentials, retry: false)

    Application.put_env(:atoll, :blob_storage,
      backend: :s3,
      s3: credentials ++ [endpoint: endpoint, bucket: bucket]
    )

    {:ok, _} = Repositories.set_status(@did, :deactivated)
    bytes = :crypto.strong_rand_bytes(4096)
    blob = upload(c.conn, c.pair.access_jwt, bytes) |> json_response(200) |> Map.fetch!("blob")
    cid = CID.create(bytes, :raw)
    assert Repo.get_by!(Blob, did: @did, cid: cid).backend == :s3
    assert Storage.get_block(cid) == {:error, :not_found}
    params = %{did: @did, cid: blob["ref"]["$link"]}

    assert %{"error" => "RepoDeactivated"} =
             c.conn |> get("/xrpc/com.atproto.sync.getBlob", params) |> json_response(400)

    {:ok, _} = Repositories.set_status(@did, :active)

    assert %{"error" => "BlobNotFound"} =
             c.conn |> get("/xrpc/com.atproto.sync.getBlob", params) |> json_response(400)

    {:ok, _} =
      Repositories.apply_writes(
        @did,
        [{:put, "com.example.record/one", %{"$type" => "com.example.record", "blob" => blob}}],
        c.key
      )

    assert c.conn |> get("/xrpc/com.atproto.sync.getBlob", params) |> response(200) == bytes
  end

  defp upload(conn, token, bytes, mime \\ "application/octet-stream") do
    conn
    |> put_req_header("content-type", mime)
    |> put_req_header("authorization", "Bearer " <> token)
    |> post(@upload, bytes)
  end
end
