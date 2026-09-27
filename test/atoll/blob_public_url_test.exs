defmodule Atoll.BlobPublicURLTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Blobs, CID, Repositories, SigningKey}
  alias Atoll.Blobs.{S3, Takedown}
  alias Atoll.Proxy.LocalViewer
  @did "did:plc:publicbloburl"

  setup do
    previous =
      for key <- [:blob_storage, :image_cdn_url_pattern],
          into: %{},
          do: {key, Application.fetch_env(:atoll, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    Application.delete_env(:atoll, :image_cdn_url_pattern)

    config = [
      backend: :s3,
      s3: [
        endpoint: "https://storage.example.com",
        bucket: "test-bucket",
        public_domain: "https://cdn.rocksky.social",
        access_key_id: "test-key",
        secret_access_key: "test-secret",
        request:
          Req.new(
            plug: fn conn ->
              assert conn.host == "storage.example.com"
              assert conn.method == "PUT"
              assert String.starts_with?(conn.request_path, "/test-bucket/blobs/")
              assert [_] = Plug.Conn.get_req_header(conn, "authorization")
              Plug.Conn.send_resp(conn, 200, "")
            end
          )
      ]
    ]

    Application.put_env(:atoll, :blob_storage, config)
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, blob} = Blobs.stage(@did, "cdn-image", "image/png")
    cid = blob["ref"]["$link"]
    %{key: key, blob: blob, cid: cid, config: config}
  end

  test "normalizes optional public domains and rejects non-origin URLs" do
    assert S3.public_domain_from_env!(nil) == nil
    assert S3.public_domain_from_env!("") == nil
    assert S3.public_domain_from_env!("cdn.rocksky.social") == "https://cdn.rocksky.social"

    assert S3.public_domain_from_env!("https://CDN.rocksky.social/") ==
             "https://cdn.rocksky.social"

    for value <- [
          "http://cdn.example.com",
          "https://cdn.example.com/bucket",
          "https://user:secret@cdn.example.com",
          "https://cdn.example.com?token=x",
          "https://cdn.example.com#fragment",
          "bad host"
        ] do
      assert_raise ArgumentError, fn -> S3.public_domain_from_env!(value) end
    end
  end

  test "builds CDN image URLs only after S3 publication, without reading object bytes", c do
    assert Blobs.public_url(@did, c.cid) == nil
    assert LocalViewer.image_url("avatar", @did, c.cid) =~ "/xrpc/com.atproto.sync.getBlob?"
    publish(c)
    expected = "https://cdn.rocksky.social/blobs/" <> c.cid
    assert Blobs.public_url(@did, c.cid) == expected

    for size <- ["avatar", "banner", "feed_thumbnail", "feed_fullsize"] do
      assert LocalViewer.image_url(size, @did, c.cid) == expected
    end

    assert LocalViewer.update_profile_basic(%{}, %{"avatar" => c.blob}, @did)["avatar"] ==
             expected

    assert Blobs.public_url("did:plc:other", c.cid) == nil
    assert Blobs.public_url(@did, "invalid") == nil
  end

  test "retains database-blob and unconfigured fallbacks and explicit CDN precedence", c do
    publish(c)
    without_domain = put_in(c.config[:s3][:public_domain], nil)
    Application.put_env(:atoll, :blob_storage, without_domain)
    assert LocalViewer.image_url("avatar", @did, c.cid) =~ "/xrpc/com.atproto.sync.getBlob?"
    Application.put_env(:atoll, :blob_storage, c.config)
    {:ok, blob} = Blobs.stage(@did, "database-image", "image/png", storage: [backend: :postgres])
    publish(%{c | blob: blob})

    assert LocalViewer.image_url("avatar", @did, blob["ref"]["$link"]) =~
             "/xrpc/com.atproto.sync.getBlob?"

    Application.put_env(:atoll, :image_cdn_url_pattern, "https://images.example.com/%s/%s/%s")

    assert LocalViewer.image_url("avatar", @did, c.cid) ==
             "https://images.example.com/avatar/#{@did}/#{c.cid}"

    assert LocalViewer.image_url("avatar", @did, nil) == nil
  end

  test "does not issue CDN links for withdrawn, inactive or taken-down blobs", c do
    publish(c)
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert Blobs.public_url(@did, c.cid) == nil
    {:ok, _} = Repositories.set_status(@did, :active)
    {:ok, cid} = CID.from_base32(c.cid)
    Repo.insert!(%Takedown{did: @did, cid: cid, ref: "test"})
    assert Blobs.public_url(@did, c.cid) == nil
    Repo.delete_all(Takedown)
    {:ok, _} = Repositories.apply_writes(@did, [{:delete, "com.example.record/image"}], c.key)
    assert Blobs.public_url(@did, c.cid) == nil
  end

  defp publish(c) do
    assert {:ok, _} =
             Repositories.apply_writes(
               @did,
               [
                 {:put, "com.example.record/image",
                  %{"$type" => "com.example.record", "image" => c.blob}}
               ],
               c.key
             )
  end
end
