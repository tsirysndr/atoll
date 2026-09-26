defmodule Atoll.BlobsTest do
  use Atoll.DataCase, async: true
  alias Atoll.{Blobs, CID, Repositories, SigningKey, Storage}
  alias Atoll.Blobs.Blob
  @did "did:plc:blobs"
  @pg [storage: [backend: :postgres]]

  setup do
    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    :ok
  end

  test "stages verified raw bytes with stable per-account metadata" do
    bytes = <<0, 255, 12>>
    cid = CID.create(bytes, :raw)
    assert {:ok, descriptor} = Blobs.stage(@did, bytes, "IMAGE/PNG", @pg)

    assert descriptor == %{
             "$type" => "blob",
             "ref" => %{"$link" => CID.to_base32(cid)},
             "mimeType" => "image/png",
             "size" => 3
           }

    assert Blobs.stage(@did, bytes, "application/octet-stream", @pg) == {:ok, descriptor}
    assert {:ok, %{blob: ^descriptor, bytes: ^bytes}} = Blobs.get_staged(@did, cid, @pg)
    assert Repo.aggregate(Blob, :count) == 1
    assert {:ok, _} = Blobs.stage(@did, "", "application/octet-stream", @pg)
  end

  test "validation rejects oversized content, length mismatches and invalid MIME declarations" do
    assert Blobs.stage(@did, String.duplicate("x", 5 * 1024 * 1024 + 1), "text/plain", @pg) ==
             {:error, :blob_too_large}

    assert Blobs.stage(@did, "x", "text/plain", @pg ++ [content_length: 2]) ==
             {:error, :content_length_mismatch}

    for mime <- [nil, "*/*", "text/plain\r\nx: y", "text/plain; charset=utf-8", "invalid"] do
      assert Blobs.stage(@did, "x", mime, @pg) == {:error, :invalid_mime_type}
    end

    assert Repo.aggregate(Blob, :count) == 0
  end

  test "ownership and inactive status prevent staged reads and writes" do
    cid = CID.create("secret", :raw)
    assert {:ok, _} = Blobs.stage(@did, "secret", "text/plain", @pg)
    other = "did:plc:otherblobs"
    {:ok, _} = Repositories.create(other, SigningKey.generate())
    assert Blobs.get_staged(other, cid, @pg) == {:error, :blob_not_found}
    assert Blobs.stage("did:plc:missing", "x", "text/plain", @pg) == {:error, :not_found}
    {:ok, _} = Repositories.set_status(@did, :suspended)
    assert Blobs.stage(@did, "x", "text/plain", @pg) == {:error, {:repo_inactive, :suspended}}
    assert Blobs.get_staged(@did, cid, @pg) == {:error, {:repo_inactive, :suspended}}
  end

  test "postgres staging rolls back metadata and bytes together" do
    cid = CID.create("rollback", :raw)

    assert {:error, :abort} =
             Repo.transaction(fn ->
               {:ok, _} = Blobs.stage(@did, "rollback", "text/plain", @pg)
               Repo.rollback(:abort)
             end)

    assert Repo.aggregate(Blob, :count) == 0
    assert Storage.get_block(cid) == {:error, :not_found}
  end

  test "S3 signs PUT/GET, preserves exact bytes, and stores no blob bytes in PostgreSQL" do
    objects = start_supervised!({Agent, fn -> %{} end})

    request =
      Req.new(
        plug: fn conn ->
          assert ["AWS4-HMAC-SHA256 " <> auth] = Plug.Conn.get_req_header(conn, "authorization")
          assert auth =~ "/us-east-1/s3/aws4_request"
          assert Plug.Conn.get_req_header(conn, "x-amz-security-token") == ["test-session"]
          assert String.starts_with?(conn.request_path, "/test-bucket/blobs/bafk")

          case conn.method do
            "PUT" ->
              {:ok, bytes, conn} = Plug.Conn.read_body(conn)
              Agent.update(objects, &Map.put(&1, conn.request_path, bytes))
              Plug.Conn.send_resp(conn, 200, "")

            "GET" ->
              Plug.Conn.send_resp(
                conn,
                200,
                Agent.get(objects, &Map.fetch!(&1, conn.request_path))
              )
          end
        end
      )

    opts = s3(request)
    bytes = <<0, 255, 1, 2>>
    cid = CID.create(bytes, :raw)
    assert {:ok, descriptor} = Blobs.stage(@did, bytes, "application/octet-stream", opts)
    assert Storage.get_block(cid) == {:error, :not_found}
    assert Repo.get_by!(Blob, did: @did, cid: cid).backend == :s3
    assert {:ok, %{blob: ^descriptor, bytes: ^bytes}} = Blobs.get_staged(@did, cid, opts)
    # Backend is selected from the stored row even after the default changes.
    switched = put_in(opts, [:storage, :backend], :postgres)
    assert {:ok, %{bytes: ^bytes}} = Blobs.get_staged(@did, cid, switched)
  end

  test "failed S3 uploads never publish ownership metadata" do
    for status <- [301, 403, 500] do
      opts = s3(Req.new(plug: fn conn -> Plug.Conn.send_resp(conn, status, "error") end))
      assert Blobs.stage(@did, "x", "text/plain", opts) == {:error, :blob_storage_unavailable}
    end

    assert Repo.aggregate(Blob, :count) == 0
  end

  test "S3 reads reject corrupt bytes and oversized responses" do
    opts = s3(Req.new(plug: fn conn -> Plug.Conn.send_resp(conn, 200, "") end))
    assert {:ok, _} = Blobs.stage(@did, "original", "text/plain", opts)
    cid = CID.create("original", :raw)

    for bytes <- ["corrupt", String.duplicate("x", 5 * 1024 * 1024 + 1)] do
      opts = s3(Req.new(plug: fn conn -> Plug.Conn.send_resp(conn, 200, bytes) end))
      assert Blobs.get_staged(@did, cid, opts) == {:error, :invalid_blob_storage}
    end
  end

  defp s3(request) do
    [
      storage: [
        backend: :s3,
        s3: [
          endpoint: "https://objects.example.com",
          bucket: "test-bucket",
          region: "us-east-1",
          access_key_id: "test-access",
          secret_access_key: "test-secret",
          session_token: "test-session",
          request: request
        ]
      ]
    ]
  end
end
