defmodule AtollWeb.RecordWriteControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{CID, Repo, Repositories}
  alias Atoll.Accounts.{Credentials, Sessions}
  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  @collection "com.example.record"
  @record %{"$type" => @collection, "text" => "original"}

  setup %{conn: conn} do
    old =
      for key <- [:session_signing_key, :key_encryption_key, :identity_resolution_options],
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

  test "batch creates distinct keys and returns ordered results under one commit", c do
    request(c, "putRecord", body("existing", %{"record" => @record})) |> json_response(200)
    request(c, "putRecord", body("remove", %{"record" => @record})) |> json_response(200)
    seq = Atoll.Repositories.Events.latest_seq()

    writes = [
      operation("create"),
      operation("create"),
      operation("update", "existing"),
      operation("delete", "remove")
    ]

    result =
      request(c, "applyWrites", %{"repo" => @did, "writes" => writes}) |> json_response(200)

    [first, second, updated, deleted] = result["results"]
    refute first["uri"] == second["uri"]
    assert first["$type"] == "com.atproto.repo.applyWrites#createResult"
    assert updated["$type"] == "com.atproto.repo.applyWrites#updateResult"
    assert deleted == %{"$type" => "com.atproto.repo.applyWrites#deleteResult"}
    assert {:ok, [event]} = Atoll.Repositories.Events.list_after(seq)
    assert event.kind == :commit
    assert length(event.payload["ops"]) == 4
    assert Repositories.get_record(@did, @collection <> "/remove") == {:error, :not_found}
    {:ok, head} = Repositories.get_head(@did)
    assert result["commit"]["cid"] == CID.to_base32(head.head)

    for entry <- [first, second] do
      assert entry["uri"] |> String.split("/") |> List.last() |> Atoll.TID.valid?()
    end
  end

  test "batch failures roll back records, blob references, revisions and events", c do
    {:ok, blob} = Atoll.Blobs.stage(@did, "batch attachment", "text/plain")
    good = Map.put(operation("create", "good"), "value", Map.put(@record, "blob", blob))
    bad_blob = put_in(blob, ["ref", "$link"], CID.to_base32(CID.create("missing", :raw)))
    bad = Map.put(operation("create", "bad"), "value", Map.put(@record, "blob", bad_blob))
    seq = Atoll.Repositories.Events.latest_seq()
    revisions = Repo.aggregate(Atoll.Repositories.Revision, :count)

    assert %{"error" => "BlobNotFound"} =
             request(c, "applyWrites", %{"repo" => @did, "writes" => [good, bad]})
             |> json_response(400)

    assert Repositories.get_head(@did) == {:ok, c.head}
    assert Repo.aggregate(Atoll.Repositories.Record, :count) == 0
    assert Repo.aggregate(Atoll.Blobs.Reference, :count) == 0
    assert Repo.aggregate(Atoll.Repositories.Revision, :count) == revisions
    assert Atoll.Repositories.Events.latest_seq() == seq
  end

  test "batch validates shape, duplicate paths, existing updates, and commit swaps", c do
    for writes <- [
          nil,
          %{},
          [%{"$type" => "unknown"}],
          [nil],
          List.duplicate(operation("create"), 201),
          [operation("create", "one"), operation("delete", "one")]
        ] do
      assert %{"error" => "InvalidRequest"} =
               request(c, "applyWrites", %{"repo" => @did, "writes" => writes})
               |> json_response(400)
    end

    assert %{"error" => "RecordNotFound"} =
             request(c, "applyWrites", %{
               "repo" => @did,
               "writes" => [operation("update", "missing")]
             })
             |> json_response(400)

    assert %{"error" => "InvalidSwap"} =
             request(c, "applyWrites", %{
               "repo" => @did,
               "writes" => [operation("create")],
               "swapCommit" => CID.to_base32(CID.create("wrong", :dag_cbor))
             })
             |> json_response(400)

    assert %{"error" => "InvalidRequest"} =
             request(c, "applyWrites", %{"repo" => @did, "writes" => [], "validate" => true})
             |> json_response(400)

    assert %{"error" => "Forbidden"} =
             request(c, "applyWrites", %{"repo" => "did:plc:other", "writes" => []})
             |> json_response(403)

    assert Repositories.get_head(@did) == {:ok, c.head}
    seq = Atoll.Repositories.Events.latest_seq()

    assert %{"results" => [], "commit" => _} =
             request(c, "applyWrites", %{
               "repo" => @did,
               "writes" => [],
               "swapCommit" => CID.to_base32(c.head.head)
             })
             |> json_response(200)

    assert Atoll.Repositories.Events.latest_seq() == seq
    {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)

    assert %{"error" => "InvalidToken"} =
             request(c, "applyWrites", %{"repo" => @did, "writes" => []}) |> json_response(401)
  end

  test "verified handles address all record writes while results use canonical DIDs", c do
    configure_handle(c)
    params = body("handle", %{"repo" => "Alice.Example.Com", "record" => @record})
    created = request(c, "createRecord", params) |> json_response(200)
    assert created["uri"] == "at://#{@did}/#{@collection}/handle"

    assert request(c, "putRecord", Map.put(params, "swapRecord", created["cid"]))
           |> json_response(200)

    assert request(c, "deleteRecord", params) |> json_response(200)

    batch =
      request(c, "applyWrites", %{
        "repo" => "alice.example.com",
        "writes" => [operation("create", "batch")]
      })
      |> json_response(200)

    assert hd(batch["results"])["uri"] == "at://#{@did}/#{@collection}/batch"
  end

  test "forward-only handles and verified handles of other accounts cannot authorize writes", c do
    for {did, claimed, code, status} <- [
          {@did, "other.example.com", "InvalidRequest", 400},
          {"did:web:other.example.com", "alice.example.com", "Forbidden", 403}
        ] do
      configure_handle(c, did, claimed)

      assert %{"error" => ^code} =
               request(
                 c,
                 "putRecord",
                 body("one", %{"repo" => "alice.example.com", "record" => @record})
               )
               |> json_response(status)

      assert %{"error" => ^code} =
               request(c, "applyWrites", %{
                 "repo" => "alice.example.com",
                 "writes" => [operation("create")]
               })
               |> json_response(status)
    end

    assert Repositories.get_head(@did) == {:ok, c.head}
    refute Repo.exists?(Atoll.Repositories.Record)
  end

  test "rejects malformed requests before resolution and bypasses lookup for DID writes", c do
    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn _ -> flunk("unexpected DNS lookup") end
    )

    params =
      body("one", %{"repo" => "alice.example.com", "record" => @record, "swapCommit" => "invalid"})

    assert %{"error" => "InvalidRequest"} = request(c, "putRecord", params) |> json_response(400)

    assert %{"error" => "InvalidRequest"} =
             request(c, "applyWrites", %{
               "repo" => "alice.example.com",
               "writes" => [%{"$type" => "invalid"}]
             })
             |> json_response(400)

    assert request(c, "putRecord", body("one", %{"record" => @record})) |> json_response(200)
    assert request(c, "applyWrites", %{"repo" => @did, "writes" => []}) |> json_response(200)
  end

  test "revocation during identity lookup prevents the later write", c do
    configure_handle(c)
    opts = Application.fetch_env!(:atoll, :identity_resolution_options)
    request = Keyword.fetch!(opts, :request)
    # Wrap the trusted test transport so revocation occurs after initial HTTP auth.
    original_plug = request.options.plug

    request =
      Req.new(
        plug: fn conn ->
          {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)
          original_plug.(conn)
        end
      )

    Application.put_env(
      :atoll,
      :identity_resolution_options,
      Keyword.put(opts, :request, request)
    )

    assert %{"error" => "InvalidToken"} =
             request(
               c,
               "putRecord",
               body("one", %{"repo" => "alice.example.com", "record" => @record})
             )
             |> json_response(401)

    assert Repositories.get_head(@did) == {:ok, c.head}
  end

  defp configure_handle(c, did \\ @did, claimed \\ "alice.example.com") do
    {:ok, public} = Atoll.Multikey.encode(c.head.curve, c.head.public_key)

    document = %{
      "id" => did,
      "alsoKnownAs" => ["at://" <> claimed],
      "verificationMethod" => [
        %{
          "id" => "#atproto",
          "controller" => did,
          "type" => "Multikey",
          "publicKeyMultibase" => public
        }
      ],
      "service" => [
        %{
          "id" => "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => "https://pds.example.com"
        }
      ]
    }

    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn name ->
        assert name == "_atproto.alice.example.com"
        [["did=" <> did]]
      end,
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      request: Req.new(plug: fn conn -> Req.Test.json(conn, document) end)
    )
  end

  defp operation(kind, rkey \\ nil) do
    value = %{"$type" => "com.atproto.repo.applyWrites#" <> kind, "collection" => @collection}
    value = if kind == "delete", do: value, else: Map.put(value, "value", @record)
    if rkey, do: Map.put(value, "rkey", rkey), else: value
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
