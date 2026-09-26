defmodule AtollWeb.RecordWriteControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{CID, Repo, Repositories}
  alias Atoll.Accounts.{Credentials, Sessions}
  @did "did:plc:httpwrites"
  @collection "com.example.record"
  @record %{"$type" => @collection, "text" => "original"}

  setup %{conn: conn} do
    old =
      for key <- [:session_signing_key, :key_encryption_key],
          do: {key, Application.fetch_env(:atoll, key)}

    on_exit(fn ->
      for {key, value} <- old do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    Application.put_env(:atoll, :session_signing_key, :binary.copy(<<17>>, 32))
    Application.put_env(:atoll, :key_encryption_key, :binary.copy(<<18>>, 32))
    {:ok, head} = Repositories.create_managed(@did)
    {:ok, _} = Credentials.create(@did, "record write password")
    {:ok, pair} = Sessions.create(@did, "record write password")
    id = rem(System.unique_integer([:positive]), 65_536)
    conn = %{conn | remote_ip: {10, 30, div(id, 256), rem(id, 256)}}
    %{conn: conn, pair: pair, head: head}
  end

  test "creates an automatic TID record, updates it, reads it and deletes it", c do
    created =
      request(c, "createRecord", %{
        "repo" => @did,
        "collection" => @collection,
        "record" => @record
      })

    assert get_resp_header(created, "cache-control") == ["no-store"]
    original = json_response(created, 200)
    rkey = original["uri"] |> String.split("/") |> List.last()
    assert Atoll.TID.valid?(rkey)
    assert original["validationStatus"] == "unknown"

    changed =
      request(
        c,
        "putRecord",
        body(rkey, %{
          "record" => Map.put(@record, "text", "updated"),
          "swapRecord" => original["cid"],
          "swapCommit" => original["commit"]["cid"]
        })
      )
      |> json_response(200)

    refute changed["cid"] == original["cid"]

    assert {:ok, %{value: %{"text" => "updated"}}} =
             Repositories.get_record(@did, @collection <> "/" <> rkey)

    assert %{"commit" => _} =
             request(c, "deleteRecord", body(rkey, %{"swapRecord" => changed["cid"]}))
             |> json_response(200)

    assert Repositories.get_record(@did, @collection <> "/" <> rkey) == {:error, :not_found}
    assert %{"commit" => _} = request(c, "deleteRecord", body(rkey)) |> json_response(200)
  end

  test "distinguishes missing and null swapRecord, and rolls back failed comparisons", c do
    original =
      request(c, "putRecord", body("one", %{"record" => @record, "swapRecord" => nil}))
      |> json_response(200)

    {:ok, head} = Repositories.get_head(@did)
    seq = Atoll.Repositories.Events.latest_seq()

    for extra <- [
          %{"swapRecord" => nil},
          %{"swapRecord" => CID.to_base32(c.head.head)},
          %{"swapCommit" => CID.to_base32(c.head.head)}
        ] do
      assert %{"error" => "InvalidSwap"} =
               request(c, "putRecord", body("one", Map.put(extra, "record", @record)))
               |> json_response(400)

      assert Repositories.get_head(@did) == {:ok, head}
      assert Atoll.Repositories.Events.latest_seq() == seq
    end

    assert %{"error" => "InvalidRequest"} =
             request(c, "createRecord", body("one", %{"record" => @record})) |> json_response(400)

    assert %{"error" => "InvalidRequest"} =
             request(c, "deleteRecord", body("one", %{"swapRecord" => nil})) |> json_response(400)

    assert request(c, "putRecord", body("one", %{"record" => @record}))
           |> json_response(200)
           |> Map.fetch!("cid") == original["cid"]
  end

  test "never writes another account and refuses refresh or revoked tokens", c do
    other = "did:plc:otherhttpwrites"
    {:ok, head} = Repositories.create_managed(other)

    assert %{"error" => "Forbidden"} =
             request(c, "putRecord", body("one", %{"record" => @record, "repo" => other}))
             |> json_response(403)

    assert Repositories.get_head(other) == {:ok, head}

    conn =
      c.conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> c.pair.refresh_jwt)

    assert %{"error" => "InvalidToken"} =
             conn
             |> post(path("putRecord"), Jason.encode!(body("one", %{"record" => @record})))
             |> json_response(401)

    {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)

    assert %{"error" => "InvalidToken"} =
             request(c, "putRecord", body("one", %{"record" => @record})) |> json_response(401)
  end

  test "rechecks session revocation after body parsing", c do
    conn =
      Plug.Test.conn(:post, path("putRecord"), Jason.encode!(body("one", %{"record" => @record})))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
      |> AtollWeb.RecordWritePlug.call([])

    {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)
    assert AtollWeb.RecordWriteController.put(conn, %{}) == {:error, :invalid_token}
    assert Repositories.get_head(@did) == {:ok, c.head}
  end

  test "rejects invalid records and unavailable required validation without mutation", c do
    for extra <- [
          %{"record" => %{"$type" => "com.example.other"}},
          %{"record" => []},
          %{"record" => @record, "validate" => true},
          %{"record" => @record, "validate" => nil},
          %{"record" => Map.put(@record, "float", 1.5)},
          %{"record" => @record, "rkey" => ".."},
          %{"record" => @record, "swapCommit" => nil}
        ] do
      assert %{"error" => "InvalidRequest"} =
               request(c, "putRecord", body("one", extra)) |> json_response(400)
    end

    assert Repositories.get_head(@did) == {:ok, c.head}
    {:ok, _} = Repositories.set_status(@did, :deactivated)

    assert %{"error" => "RepoDeactivated"} =
             request(c, "putRecord", body("one", %{"record" => @record})) |> json_response(400)
  end

  test "bounded parsing and encoded route limits run before the general parser", c do
    assert response(get(c.conn, path("putRecord")), 405)
    conn = c.conn |> put_req_header("content-type", "application/json")

    assert %{"error" => "AuthRequired"} =
             conn |> post(path("putRecord"), "{") |> json_response(401)

    conn = put_req_header(conn, "authorization", "Bearer " <> c.pair.access_jwt)

    assert %{"error" => "InvalidRequest"} =
             conn |> post(path("putRecord"), "{") |> json_response(400)

    assert %{"error" => "InvalidRequest"} =
             conn
             |> post(path("putRecord"), String.duplicate("x", 2 * 1024 * 1024 + 1))
             |> json_response(413)

    assert %{"error" => "InvalidRequest"} =
             conn |> post(path("putRecord") <> "?repo=" <> @did, "{}") |> json_response(400)

    for _ <- 1..300,
        do: Atoll.Accounts.SessionLimiter.check({:record_write, c.conn.remote_ip}, 300)

    assert %{"error" => "RateLimitExceeded"} =
             conn |> post("/xrpc/com.atproto.repo.%70utRecord", "{}") |> json_response(429)
  end

  test "publishes uploaded blobs and withdraws them when a record is deleted", c do
    blob =
      c.conn
      |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
      |> put_req_header("content-type", "text/plain")
      |> post("/xrpc/com.atproto.repo.uploadBlob", "attachment")
      |> json_response(200)
      |> Map.fetch!("blob")

    {:ok, cid} = CID.from_base32(blob["ref"]["$link"])
    assert Atoll.Blobs.get_public(@did, cid) == {:error, :blob_not_found}

    assert request(c, "putRecord", body("one", %{"record" => Map.put(@record, "blob", blob)}))
           |> json_response(200)

    assert {:ok, %{bytes: "attachment"}} = Atoll.Blobs.get_public(@did, cid)
    assert request(c, "deleteRecord", body("one")) |> json_response(200)
    assert Atoll.Blobs.get_public(@did, cid) == {:error, :blob_not_found}
    assert Repo.aggregate(Atoll.Blobs.CleanupJob, :count) == 1
  end

  defp body(rkey, extra \\ %{}),
    do: Map.merge(%{"repo" => @did, "collection" => @collection, "rkey" => rkey}, extra)

  defp path(method), do: "/xrpc/com.atproto.repo." <> method

  defp request(c, method, body) do
    c.conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
    |> post(path(method), Jason.encode!(body))
  end
end
