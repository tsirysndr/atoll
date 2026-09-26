defmodule AtollWeb.BlobControllerTest do
  use AtollWeb.ConnCase, async: true
  alias Atoll.{Blobs, Repositories, SigningKey}
  @did "did:plc:blobhttp"
  @get "/xrpc/com.atproto.sync.getBlob"
  @list "/xrpc/com.atproto.sync.listBlobs"

  setup do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, blob} = Blobs.stage(@did, "<svg></svg>", "image/svg+xml")
    %{blob: blob, cid: blob["ref"]["$link"], key: key}
  end

  test "staged blobs are hidden; referenced blobs return original bytes and restrictive headers",
       c do
    assert json_response(get(c.conn, @get, did: @did, cid: c.cid), 400)["error"] == "BlobNotFound"
    {:ok, _} = publish(c)
    response = get(c.conn, @get, did: @did, cid: c.cid)
    assert response(response, 200) == "<svg></svg>"
    assert get_resp_header(response, "content-type") == ["image/svg+xml"]
    assert get_resp_header(response, "content-length") == ["11"]
    assert get_resp_header(response, "content-security-policy") == ["default-src 'none'; sandbox"]
    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert json_response(get(c.conn, @list, did: @did), 200) == %{"cids" => [c.cid]}
  end

  test "inactive repositories reject both endpoints", c do
    {:ok, _} = publish(c)
    {:ok, _} = Repositories.set_status(@did, :deactivated)

    for path <- [@get, @list] do
      assert json_response(get(c.conn, path, did: @did, cid: c.cid), 400)["error"] ==
               "RepoDeactivated"
    end
  end

  test "malformed query parameters return XRPC errors", c do
    for params <- [[did: @did, cid: "bad"], [cid: c.cid]] do
      assert json_response(get(c.conn, @get, params), 400)["error"] == "InvalidRequest"
    end

    for params <- [[did: @did, limit: 0], [did: @did, cursor: "bad"], [did: @did, since: "bad"]] do
      assert json_response(get(c.conn, @list, params), 400)["error"] == "InvalidRequest"
    end
  end

  defp publish(c),
    do:
      Repositories.apply_writes(
        @did,
        [{:put, "com.example.record/one", %{"$type" => "com.example.record", "blob" => c.blob}}],
        c.key
      )
end
