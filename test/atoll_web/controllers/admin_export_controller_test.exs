defmodule AtollWeb.AdminExportControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Blobs, CID, Repositories, SigningKey}
  @did "did:web:admin-export.example.com"
  @secret "operator-export-secret-at-least-32"
  @repo "/xrpc/com.atproto.sync.getRepo"
  @blob "/xrpc/com.atproto.sync.getBlob"
  @list "/xrpc/com.atproto.sync.listBlobs"

  setup %{conn: conn} do
    prior = Application.fetch_env(:atoll, :admin_password)
    Application.put_env(:atoll, :admin_password, @secret)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:atoll, :admin_password, value)
        :error -> Application.delete_env(:atoll, :admin_password)
      end
    end)

    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, blob} = Blobs.stage(@did, "operator export bytes", "text/plain")

    {:ok, _} =
      Repositories.apply_writes(
        @did,
        [{:put, "com.example.record/one", %{"$type" => "com.example.record", "blob" => blob}}],
        key
      )

    {:ok, car} = Repositories.export(@did)
    id = rem(System.unique_integer([:positive]), 65_536)

    %{
      conn: %{conn | remote_ip: {10, 66, div(id, 256), rem(id, 256)}},
      car: car,
      cid: blob["ref"]["$link"]
    }
  end

  test "operators export any local availability without making inactive repositories public", c do
    for status <- [:active, :deactivated, :takendown, :suspended] do
      {:ok, _} = Repositories.set_status(@did, status)
      result = auth(c.conn) |> get(@repo, %{did: @did})
      assert response(result, 200) == c.car
      assert get_resp_header(result, "cache-control") == ["no-store"]

      assert response(auth(c.conn) |> get(@blob, %{did: @did, cid: c.cid}), 200) ==
               "operator export bytes"

      assert auth(c.conn) |> get(@list, %{did: @did}) |> json_response(200) == %{
               "cids" => [c.cid]
             }

      if status != :active do
        for {path, params} <- requests(c) do
          assert get(c.conn, path, params) |> json_response(400)
        end
      end
    end
  end

  test "operator exports still require references and honor individual blob takedowns", c do
    {:ok, staged} = Blobs.stage(@did, "unreferenced", "text/plain")

    assert auth(c.conn)
           |> get(@blob, %{did: @did, cid: staged["ref"]["$link"]})
           |> json_response(400)

    {:ok, _} =
      Atoll.Accounts.SubjectStatus.update(%{
        "subject" => %{
          "$type" => "com.atproto.admin.defs#repoBlobRef",
          "did" => @did,
          "cid" => c.cid
        },
        "takedown" => %{"applied" => true}
      })

    assert auth(c.conn) |> get(@blob, %{did: @did, cid: c.cid}) |> json_response(400)
    assert auth(c.conn) |> get(@list, %{did: @did}) |> json_response(200) == %{"cids" => []}
    assert response(auth(c.conn) |> get(@repo, %{did: @did}), 200) == c.car
  end

  test "bad or disabled admin credentials fail before parsing and cannot use public fallback",
       c do
    for {path, params} <- requests(c) do
      assert auth(c.conn, "wrong") |> get(path, params) |> json_response(401)
      assert auth(c.conn, "wrong") |> get(path <> "?invalid=%ZZ") |> json_response(401)
      assert auth(c.conn) |> post(path, %{}) |> json_response(405)
    end

    Application.delete_env(:atoll, :admin_password)
    assert auth(c.conn) |> get(@repo, %{did: @did}) |> json_response(503)
    assert response(get(c.conn, @repo, %{did: @did}), 200) == c.car
  end

  test "storage rechecks the credential instead of trusting an admin flag", c do
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    headers = ["Basic " <> Base.encode64("admin:" <> @secret)]
    assert {:ok, car} = Repositories.export(@did, nil, {:admin, headers})
    assert car == c.car
    Application.put_env(:atoll, :admin_password, @secret <> "-rotated")
    {:ok, cid} = CID.from_base32(c.cid)
    assert {:error, :invalid_token} = Repositories.export(@did, nil, {:admin, headers})
    assert {:error, :invalid_token} = Blobs.get_public(@did, cid, token: {:admin, headers})
    assert {:error, :invalid_token} = Blobs.list_public(@did, 10, nil, nil, {:admin, headers})
    assert {:error, _} = Repositories.export(@did, nil, :admin)
  end

  test "operator exports share the administrative rate limit", c do
    for _ <- 1..60,
        do: assert(auth(c.conn, "wrong") |> get(@repo, %{did: @did}) |> json_response(401))

    result = auth(c.conn) |> get(@list, %{did: @did})
    assert json_response(result, 429)["error"] == "RateLimitExceeded"
    assert get_resp_header(result, "retry-after") != []
  end

  defp requests(c),
    do: [{@repo, %{did: @did}}, {@blob, %{did: @did, cid: c.cid}}, {@list, %{did: @did}}]

  defp auth(conn, password \\ @secret),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("admin:" <> password))
end
