defmodule Atoll.BlobInventoryTest do
  use Atoll.DataCase, async: false
  alias Atoll.{CID, Repositories, SigningKey}
  alias Atoll.Blobs.{Blob, CleanupJob, Inventory}
  @did "did:web:inventory.example.com"

  setup do
    {:ok, _} = Repositories.create(@did, SigningKey.generate())

    storage = [
      backend: :s3,
      s3: [
        endpoint: "https://s3.example.com",
        bucket: "atoll-test",
        access_key_id: "key",
        secret_access_key: "secret",
        request: Req.new(plug: {Req.Test, __MODULE__})
      ]
    ]

    previous = Application.fetch_env(:atoll, :blob_storage)
    Application.put_env(:atoll, :blob_storage, storage)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atoll, :blob_storage, value)
        :error -> Application.delete_env(:atoll, :blob_storage)
      end
    end)

    :ok
  end

  test "ownership wins over queued cleanup and PostgreSQL ownership does not claim S3 objects" do
    owned = CID.create("owned", :raw)
    postgres = CID.create("postgres", :raw)
    queued = CID.create("queued", :raw)

    for {cid, backend} <- [{owned, :s3}, {postgres, :postgres}] do
      Repo.insert!(%Blob{
        did: @did,
        cid: cid,
        backend: backend,
        mime_type: "text/plain",
        size: 5,
        staged_at: DateTime.utc_now()
      })
    end

    for cid <- [owned, queued],
        do: Repo.insert!(%CleanupJob{cid: cid, backend: :s3, queued_at: DateTime.utc_now()})

    keys =
      Enum.map([owned, postgres, queued], &("blobs/" <> CID.to_base32(&1))) ++
        ["blobs/" <> CID.to_base32(CID.create("record", :dag_cbor))]

    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, listing(keys)))
    assert {:ok, page} = Inventory.page()

    assert Enum.map(page.objects, & &1.status) == [
             "owned",
             "untracked",
             "pending_cleanup",
             "unrecognized_key"
           ]

    assert page.counts == %{
             "owned" => 1,
             "untracked" => 1,
             "pending_cleanup" => 1,
             "unrecognized_key" => 1
           }

    assert Repo.aggregate(Blob, :count) == 2
    assert Repo.aggregate(CleanupJob, :count) == 2
  end

  test "operator CLI exports JSON but rejects unknown and duplicate flags" do
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 200, listing([])))

    output =
      ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Atoll.Blobs.Inventory.run(["--limit", "1"]) end)

    assert Jason.decode!(output) == %{"objects" => [], "counts" => %{}}

    for args <- [
          ["--delete"],
          ["--limit", "0"],
          ["--limit", "1", "--limit", "2"],
          ["--cursor", ""]
        ] do
      assert_raise Mix.Error, fn -> Mix.Tasks.Atoll.Blobs.Inventory.run(args) end
    end
  end

  test "repeated continuation tokens and non-S3 configuration fail without mutations" do
    Req.Test.expect(
      __MODULE__,
      &Plug.Conn.send_resp(
        &1,
        200,
        String.replace(
          listing([]),
          "<IsTruncated>false</IsTruncated>",
          "<IsTruncated>true</IsTruncated><NextContinuationToken>same</NextContinuationToken>"
        )
      )
    )

    assert {:error, :invalid_inventory_query} = Inventory.page(1, "same")

    assert {:error, :invalid_inventory_query} =
             Inventory.page(1, nil, storage: [backend: :postgres])
  end

  defp listing(keys) do
    contents =
      Enum.map_join(keys, fn key ->
        "<Contents><Key>#{URI.encode_www_form(key)}</Key><Size>5</Size><LastModified>2026-09-26T00:00:00Z</LastModified></Contents>"
      end)

    "<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>#{contents}</ListBucketResult>"
  end
end
