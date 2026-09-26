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
    key = SigningKey.generate()
    assert {:ok, _} = Repositories.create(@did, key)

    %{
      config: config,
      key: key,
      opts: [storage: [backend: :s3, s3: config]],
      bucket_url: endpoint <> "/" <> bucket
    }
  end

  test "inventory paginates real objects and reports ownership without deleting anything", c do
    {:ok, _} = Blobs.stage(@did, "tracked inventory", "text/plain", c.opts)
    tracked = CID.create("tracked inventory", :raw)
    orphan = CID.create("untracked inventory", :raw)
    queued = CID.create("queued inventory", :raw)
    assert :ok = Atoll.Blobs.S3.put(orphan, "untracked inventory", c.config)
    assert :ok = Atoll.Blobs.S3.put(queued, "queued inventory", c.config)

    Repo.insert!(%Atoll.Blobs.CleanupJob{
      cid: queued,
      backend: :s3,
      queued_at: DateTime.utc_now()
    })

    assert {:ok, %{status: 200}} =
             s3_request(:put, c.bucket_url <> "/blobs/not-a-cid", "foreign", c.config)

    {objects, cursor} =
      Enum.reduce_while(1..10, {[], nil}, fn _, {objects, cursor} ->
        assert {:ok, page} = Atoll.Blobs.Inventory.page(1, cursor, c.opts)
        assert length(page.objects) <= 1
        next = {objects ++ page.objects, Map.get(page, :cursor)}
        if Map.has_key?(page, :cursor), do: {:cont, next}, else: {:halt, next}
      end)

    assert is_nil(cursor)
    assert length(objects) == 4
    assert length(Enum.uniq_by(objects, & &1.key)) == 4
    states = Map.new(objects, &{&1.key, &1.status})
    assert states["blobs/" <> CID.to_base32(tracked)] == "owned"
    assert states["blobs/" <> CID.to_base32(orphan)] == "untracked"
    assert states["blobs/" <> CID.to_base32(queued)] == "pending_cleanup"
    assert states["blobs/not-a-cid"] == "unrecognized_key"
    assert {:ok, "untracked inventory"} = Atoll.Blobs.S3.get(orphan, c.config)
    assert {:ok, "queued inventory"} = Atoll.Blobs.S3.get(queued, c.config)
    assert Repo.get_by!(Atoll.Blobs.CleanupJob, cid: queued, backend: :s3)
  end

  test "real signed uploads and downloads preserve empty, binary and maximum-sized blobs", %{
    opts: opts,
    key: key
  } do
    for bytes <- ["", <<0, 255, 1, 128>>, :crypto.strong_rand_bytes(5 * 1024 * 1024)] do
      cid = CID.create(bytes, :raw)
      assert {:ok, descriptor} = Blobs.stage(@did, bytes, "application/octet-stream", opts)
      assert {:ok, %{blob: ^descriptor, bytes: ^bytes}} = Blobs.get_staged(@did, cid, opts)
      assert Storage.get_block(cid) == {:error, :not_found}
      assert Repo.get_by!(Blob, did: @did, cid: cid).backend == :s3
      assert Blobs.stage(@did, bytes, "text/plain", opts) == {:ok, descriptor}
      assert Blobs.get_public(@did, cid, opts) == {:error, :blob_not_found}
      path = "com.example.record/" <> CID.to_base32(cid)
      record = %{"$type" => "com.example.record", "attachment" => descriptor}
      assert {:ok, _} = Repositories.apply_writes(@did, [{:put, path, record}], key)
      assert {:ok, %{bytes: ^bytes}} = Blobs.get_public(@did, cid, opts)
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

  test "cleanup preserves shared S3 objects and retries failed deletes", context do
    alias Atoll.Blobs.{Cleanup, CleanupJob}
    bytes = "cleanup-in-minio"
    cid = CID.create(bytes, :raw)
    path = "com.example.record/cleanup"
    other = "did:plc:miniocleanupother"
    {:ok, _} = Repositories.create(other, context.key)

    for did <- [@did, other] do
      {:ok, blob} = Blobs.stage(did, bytes, "text/plain", context.opts)

      {:ok, _} =
        Repositories.apply_writes(
          did,
          [{:put, path, %{"$type" => "com.example.record", "blob" => blob}}],
          context.key
        )
    end

    {:ok, _} = Repositories.apply_writes(@did, [{:delete, path}], context.key)
    assert {:ok, %{retained: 1, deleted: 0}} = Cleanup.collect(context.opts)
    assert {:ok, %{bytes: ^bytes}} = Blobs.get_public(other, cid, context.opts)

    {:ok, _} = Repositories.apply_writes(other, [{:delete, path}], context.key)
    bad = put_in(context.opts, [:storage, :s3, :secret_access_key], "wrong-secret")
    assert {:ok, %{failed: 1, deleted: 0}} = Cleanup.collect(bad)
    assert Repo.aggregate(CleanupJob, :count) == 1
    url = context.bucket_url <> "/blobs/" <> CID.to_base32(cid)
    assert {:ok, %{status: 200, body: ^bytes}} = s3_request(:get, url, "", context.config)
    assert {:ok, %{deleted: 1, failed: 0}} = Cleanup.collect(context.opts)
    assert Repo.aggregate(CleanupJob, :count) == 0
    assert {:ok, %{status: 404}} = s3_request(:get, url, "", context.config)
    assert {:ok, _} = Blobs.stage(@did, bytes, "text/plain", context.opts)
    assert {:ok, %{bytes: ^bytes}} = Blobs.get_staged(@did, cid, context.opts)
  end

  test "operator deletion queues S3 removal without deleting another account's bytes", c do
    other = "did:plc:miniodeletionsurvivor"
    {:ok, _} = Repositories.create(other, c.key)

    for did <- [@did, other],
        do: assert({:ok, _} = Blobs.stage(did, "shared deletion bytes", "text/plain", c.opts))

    assert {:ok, _} = Blobs.stage(@did, "unique deletion bytes", "text/plain", c.opts)
    shared = CID.create("shared deletion bytes", :raw)
    unique = CID.create("unique deletion bytes", :raw)
    assert {:ok, :deleted} = Atoll.Accounts.Deletion.admin_delete(%{"did" => @did})
    assert {:ok, %{deleted: 1, retained: 1}} = Atoll.Blobs.Cleanup.collect(c.opts)
    assert {:ok, %{bytes: "shared deletion bytes"}} = Blobs.get_staged(other, shared, c.opts)
    url = c.bucket_url <> "/blobs/" <> CID.to_base32(unique)
    assert {:ok, %{status: 404}} = s3_request(:get, url, "", c.config)
    assert {:ok, %{entries: [entry]}} = Atoll.Moderation.Audit.list(100, 0, @did)
    assert entry.after == %{"availability" => "deleted"}
  end

  test "S3 bytes remain private to the moderated account and restoration uses retained data", c do
    bytes = "shared moderated S3 object"
    cid = CID.create(bytes, :raw)
    text = CID.to_base32(cid)
    other = "did:plc:miniomoderationother"
    {:ok, _} = Repositories.create(other, c.key)

    for did <- [@did, other] do
      {:ok, blob} = Blobs.stage(did, bytes, "text/plain", c.opts)

      {:ok, _} =
        Repositories.apply_writes(
          did,
          [
            {:put, "com.example.record/moderation",
             %{"$type" => "com.example.record", "blob" => blob}}
          ],
          c.key
        )
    end

    subject = %{"$type" => "com.atproto.admin.defs#repoBlobRef", "did" => @did, "cid" => text}

    assert {:ok, _} =
             Atoll.Accounts.SubjectStatus.update(%{
               "subject" => subject,
               "takedown" => %{"applied" => true}
             })

    assert {:error, :blob_not_found} = Blobs.get_public(@did, cid, c.opts)
    assert {:ok, %{cids: []}} = Blobs.list_public(@did, 10)
    assert {:error, :blob_taken_down} = Blobs.stage(@did, bytes, "text/plain", c.opts)
    assert {:ok, %{bytes: ^bytes}} = Blobs.get_public(other, cid, c.opts)

    assert {:ok, _} =
             Atoll.Accounts.SubjectStatus.update(%{
               "subject" => subject,
               "takedown" => %{"applied" => false}
             })

    assert {:ok, %{bytes: ^bytes}} = Blobs.get_public(@did, cid, c.opts)
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
