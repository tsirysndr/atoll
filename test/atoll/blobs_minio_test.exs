defmodule Atoll.BlobsMinioTest do
  use Atoll.DataCase, async: true
  alias Atoll.{Blobs, CID, Repositories, SigningKey, Storage}
  alias Atoll.Blobs.Blob
  @moduletag :minio
  @did "did:plc:minio"

  setup do
    endpoint = System.fetch_env!("ATOLL_MINIO_TEST_ENDPOINT")
    # This suite creates buckets only on the disposable local server launched by the script.
    assert %URI{scheme: "http", host: "127.0.0.1"} = URI.parse(endpoint)
    bucket = "atoll-test-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    config = [
      endpoint: endpoint,
      bucket: bucket,
      region: "us-east-1",
      access_key_id: "atoll-test",
      secret_access_key: "atoll-minio-test-only"
    ]

    assert {:ok, %{status: 200}} = s3_request(:put, endpoint <> "/" <> bucket, "", config)
    assert {:ok, _} = Repositories.create(@did, SigningKey.generate())

    %{
      config: config,
      opts: [storage: [backend: :s3, s3: config]],
      bucket_url: endpoint <> "/" <> bucket
    }
  end

  test "real signed uploads and downloads preserve empty, binary and maximum-sized blobs", %{
    opts: opts
  } do
    for bytes <- ["", <<0, 255, 1, 128>>, :crypto.strong_rand_bytes(5 * 1024 * 1024)] do
      cid = CID.create(bytes, :raw)
      assert {:ok, descriptor} = Blobs.stage(@did, bytes, "application/octet-stream", opts)
      assert {:ok, %{blob: ^descriptor, bytes: ^bytes}} = Blobs.get_staged(@did, cid, opts)
      assert Storage.get_block(cid) == {:error, :not_found}
      assert Repo.get_by!(Blob, did: @did, cid: cid).backend == :s3
      assert Blobs.stage(@did, bytes, "text/plain", opts) == {:ok, descriptor}
    end
  end

  test "the bucket is private and ownership is enforced separately from object existence",
       context do
    bytes = "account-scoped"
    cid = CID.create(bytes, :raw)
    assert {:ok, _} = Blobs.stage(@did, bytes, "text/plain", context.opts)
    url = context.bucket_url <> "/blobs/" <> CID.to_base32(cid)
    assert {:ok, %{status: 403}} = Req.get(url, retry: false, redirect: false)
    other = "did:plc:minioother"
    {:ok, _} = Repositories.create(other, SigningKey.generate())
    assert Blobs.get_staged(other, cid, context.opts) == {:error, :blob_not_found}
    assert {:ok, _} = Blobs.stage(other, bytes, "application/octet-stream", context.opts)
    assert {:ok, %{bytes: ^bytes}} = Blobs.get_staged(other, cid, context.opts)
  end

  test "invalid signing credentials and missing buckets leave no metadata", context do
    bad_key = put_in(context.opts, [:storage, :s3, :secret_access_key], "wrong-secret")

    assert Blobs.stage(@did, "bad signature", "text/plain", bad_key) ==
             {:error, :blob_storage_unavailable}

    missing = put_in(context.opts, [:storage, :s3, :bucket], "atoll-missing-bucket")

    assert Blobs.stage(@did, "missing bucket", "text/plain", missing) ==
             {:error, :blob_storage_unavailable}

    assert Repo.aggregate(Blob, :count) == 0
  end

  test "object corruption and disappearance are detected on reads", context do
    cid = CID.create("original", :raw)
    assert {:ok, _} = Blobs.stage(@did, "original", "text/plain", context.opts)
    url = context.bucket_url <> "/blobs/" <> CID.to_base32(cid)
    assert {:ok, %{status: 200}} = s3_request(:put, url, "tampered", context.config)
    assert Blobs.get_staged(@did, cid, context.opts) == {:error, :invalid_blob_storage}
    assert {:ok, %{status: 204}} = s3_request(:delete, url, "", context.config)
    assert Blobs.get_staged(@did, cid, context.opts) == {:error, :invalid_blob_storage}
  end

  defp s3_request(method, url, body, config) do
    signing =
      Keyword.take(config, [:region, :access_key_id, :secret_access_key])
      |> Keyword.put(:service, :s3)

    Req.request(
      method: method,
      url: url,
      body: body,
      aws_sigv4: signing,
      retry: false,
      redirect: false,
      raw: true,
      receive_timeout: 5000
    )
  end
end
