defmodule AtollWeb.AdminSubjectControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, Repositories, SigningKey}
  alias Atoll.Accounts.Sessions
  alias Atoll.Repositories.Events
  @did "did:web:moderated.example.com"
  @subject %{"$type" => "com.atproto.admin.defs#repoRef", "did" => @did}
  @get "/xrpc/com.atproto.admin.getSubjectStatus"
  @update "/xrpc/com.atproto.admin.updateSubjectStatus"
  @secret "separate-operator-password-for-subject-tests"

  setup %{conn: conn} do
    previous =
      Map.new([:admin_password, :session_signing_key], &{&1, Application.fetch_env(:atoll, &1)})

    Application.put_env(:atoll, :admin_password, @secret)
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, pair} = Sessions.create_for_account(@did)
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 61, div(id, 256), rem(id, 256)}}, key: key, pair: pair}
  end

  test "account takedown gates existing sessions and exports, emits one event, and restores availability",
       c do
    initial = auth(c.conn) |> get(@get, %{did: @did})
    assert get_resp_header(initial, "cache-control") == ["no-store"]

    assert %{
             "subject" => @subject,
             "takedown" => %{"applied" => false},
             "deactivated" => %{"applied" => false}
           } = json_response(initial, 200)

    seq = Events.latest_seq()
    params = %{"takedown" => %{"applied" => true, "ref" => "private-case-123"}}
    taken = update(c, params) |> json_response(200)
    assert taken["takedown"] == params["takedown"]
    assert update(c, params) |> json_response(200) == taken
    assert {:error, {:repo_inactive, :takendown}} = Repositories.export(@did)
    assert {:error, {:repo_inactive, :takendown}} = Sessions.authenticate(c.pair.access_jwt)

    assert {:error, {:repo_inactive, :takendown}} =
             Sessions.authenticate_management(c.pair.access_jwt)

    assert {:error, {:repo_inactive, :takendown}} =
             Repositories.apply_writes(
               @did,
               [{:put, "com.example.record/one", %{"$type" => "com.example.record"}}],
               c.key
             )

    assert {:ok, [event]} = Events.list_after(seq)
    assert event.kind == :account
    assert event.payload == %{"active" => false, "status" => "takendown"}

    update(c, %{"takedown" => %{"applied" => true, "ref" => "updated-case"}})
    |> json_response(200)

    assert {:ok, [_]} = Events.list_after(seq)

    assert (auth(c.conn) |> get(@get, %{did: @did}) |> json_response(200))["takedown"]["ref"] ==
             "updated-case"

    restored = update(c, %{"takedown" => %{"applied" => false}}) |> json_response(200)
    assert restored["takedown"] == %{"applied" => false}
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
    assert {:ok, _} = Repositories.export(@did)
    assert {:ok, [_, restored_event]} = Events.list_after(seq)
    assert restored_event.payload == %{"active" => true, "status" => "active"}
    assert {:ok, %{pre_takedown_status: nil, takedown_ref: nil}} = Repositories.get_head(@did)
  end

  test "lifting takedowns preserves deactivation and suspension", c do
    for status <- [:deactivated, :suspended] do
      {:ok, _} = Repositories.set_status(@did, status)
      update(c, %{"takedown" => %{"applied" => true}}) |> json_response(200)
      current = auth(c.conn) |> get(@get, %{did: @did}) |> json_response(200)
      assert current["deactivated"]["applied"] == (status == :deactivated)
      update(c, %{"takedown" => %{"applied" => false}}) |> json_response(200)
      assert {:ok, %{status: ^status}} = Repositories.get_head(@did)
    end

    assert update(c, %{"deactivated" => %{"applied" => false}}) |> json_response(400)
    assert {:ok, %{status: :suspended}} = Repositories.get_head(@did)
  end

  test "deactivation changes remain underneath takedown until the operator lifts it", c do
    update(c, %{"takedown" => %{"applied" => true}}) |> json_response(200)
    seq = Events.latest_seq()
    update(c, %{"deactivated" => %{"applied" => true}}) |> json_response(200)
    assert Events.latest_seq() == seq

    assert {:ok, %{status: :takendown, pre_takedown_status: :deactivated}} =
             Repositories.get_head(@did)

    update(c, %{"takedown" => %{"applied" => false}}) |> json_response(200)
    assert {:ok, %{status: :deactivated}} = Repositories.get_head(@did)
    update(c, %{"deactivated" => %{"applied" => false}}) |> json_response(200)
    assert {:ok, %{status: :active}} = Repositories.get_head(@did)
  end

  test "invalid combinations and unsupported subjects do not change state or events", c do
    seq = Events.latest_seq()
    {:ok, original} = Repositories.get_head(@did)

    for params <- [
          %{"takedown" => %{"applied" => true}, "deactivated" => %{"applied" => false}},
          %{"takedown" => %{"applied" => "true"}},
          %{"takedown" => nil},
          %{"takedown" => %{"applied" => true, "ref" => nil}},
          %{"takedown" => %{"applied" => true, "ref" => String.duplicate("a", 2001)}},
          %{"takedown" => %{"applied" => true, "ref" => "bad\u0000ref"}},
          %{"takedown" => %{"applied" => true, "extra" => 1}},
          %{"extra" => true},
          %{"subject" => %{"$type" => "com.example.future", "did" => @did}},
          %{"subject" => Map.put(@subject, "did", "not-a-did")}
        ] do
      assert update(c, params) |> json_response(400)
      assert {:ok, ^original} = Repositories.get_head(@did)
      assert Events.latest_seq() == seq
    end

    missing = Map.put(@subject, "did", "did:web:missing.example.com")
    assert %{"error" => "NotFound"} = update(c, %{"subject" => missing}) |> json_response(400)
    assert auth(c.conn) |> get(@get, %{did: missing["did"]}) |> json_response(400)
    assert auth(c.conn) |> get(@get, %{}) |> json_response(400)
    assert auth(c.conn) |> get(@get, %{did: @did, extra: "unexpected"}) |> json_response(400)
    assert Events.latest_seq() == seq
  end

  test "authentication precedes parsing and neither existing user sessions nor disabled admin configuration grant access",
       c do
    for conn <- [c.conn, put_req_header(c.conn, "authorization", "Bearer " <> c.pair.access_jwt)] do
      assert conn |> get(@get, %{did: @did}) |> json_response(401)

      assert conn
             |> put_req_header("content-type", "application/json")
             |> post(@update, "{")
             |> json_response(401)
    end

    assert auth(c.conn)
           |> put_req_header("content-type", "application/json")
           |> post(@update, String.duplicate(" ", 16_385))
           |> json_response(413)

    assert auth(c.conn) |> get(@get <> "?did=#{@did}&did=#{@did}") |> json_response(400)

    assert get(c.conn, "/xrpc/com.atproto.admin.%67etSubjectStatus", %{did: @did})
           |> json_response(401)

    assert auth(c.conn) |> get(@update) |> json_response(405)
    Application.delete_env(:atoll, :admin_password)
    assert auth(c.conn) |> get(@get, %{did: @did}) |> json_response(503)
    assert update(c, %{"takedown" => %{"applied" => true}}) |> json_response(503)
    assert {:ok, %{status: :active}} = Repositories.get_head(@did)
  end

  test "outer transaction rollback restores moderation state and its public event" do
    seq = Events.latest_seq()

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        Atoll.Accounts.SubjectStatus.update(%{
                          "subject" => @subject,
                          "takedown" => %{"applied" => true}
                        })

               Repo.rollback(:cancelled)
             end)

    assert {:ok, %{status: :active, pre_takedown_status: nil}} = Repositories.get_head(@did)
    assert Events.latest_seq() == seq
  end

  test "read and write moderation routes share the bounded operator rate limit", c do
    for _ <- 1..60, do: assert(c.conn |> get(@get, %{did: @did}) |> json_response(401))
    result = update(c, %{"takedown" => %{"applied" => true}})
    assert json_response(result, 429)["error"] == "RateLimitExceeded"
    assert get_resp_header(result, "retry-after") != []
    assert {:ok, %{status: :active}} = Repositories.get_head(@did)
  end

  test "moderation references are filtered from request parameters" do
    assert Phoenix.Logger.filter_values(%{"takedown" => %{"ref" => "private-case"}}) ==
             %{"takedown" => %{"ref" => "[FILTERED]"}}
  end

  test "blob takedowns hide only the selected account's bytes and block re-upload and new references",
       c do
    alias Atoll.{Blobs, CID}
    bytes = "moderated shared bytes"
    {:ok, blob} = Blobs.stage(@did, bytes, "text/plain")
    cid = CID.create(bytes, :raw)
    text = CID.to_base32(cid)
    subject = %{"$type" => "com.atproto.admin.defs#repoBlobRef", "did" => @did, "cid" => text}
    other = "did:web:unaffected.example.com"
    {:ok, _} = Repositories.create(other, c.key)
    {:ok, _} = Blobs.stage(other, bytes, "text/plain")
    value = %{"$type" => "com.example.record", "blob" => blob}

    for did <- [@did, other],
        do:
          assert(
            {:ok, _} =
              Repositories.apply_writes(did, [{:put, "com.example.record/one", value}], c.key)
          )

    seq = Events.latest_seq()
    params = %{"subject" => subject, "takedown" => %{"applied" => true, "ref" => "blob-case"}}
    assert update(c, params) |> json_response(200) == params
    assert update(c, params) |> json_response(200) == params
    assert auth(c.conn) |> get(@get, %{did: @did, blob: text}) |> json_response(200) == params

    assert get(c.conn, "/xrpc/com.atproto.sync.getBlob", %{did: @did, cid: text})
           |> json_response(400)

    assert get(c.conn, "/xrpc/com.atproto.sync.listBlobs", %{did: @did}) |> json_response(200) ==
             %{"cids" => []}

    assert {:ok, %{bytes: ^bytes}} = Blobs.get_public(other, cid)
    assert {:ok, %{cids: [^text]}} = Blobs.list_public(other, 1)
    assert {:error, :blob_taken_down} = Blobs.get_staged(@did, cid)

    upload =
      c.conn
      |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
      |> put_req_header("content-type", "text/plain")
      |> post("/xrpc/com.atproto.repo.uploadBlob", bytes)

    assert json_response(upload, 400)["error"] == "BlobTakendown"

    assert {:error, :blob_taken_down} =
             Repositories.apply_writes(@did, [{:put, "com.example.record/two", value}], c.key)

    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
    assert Events.latest_seq() == seq
    # The signed record retains its descriptor; moderation does not rewrite signed data.
    assert {:ok, _} = Repositories.get_record(@did, "com.example.record/one")
    update(c, %{"subject" => subject, "takedown" => %{"applied" => false}}) |> json_response(200)
    assert {:ok, %{bytes: ^bytes}} = Blobs.get_public(@did, cid)
    assert {:ok, %{cids: [^text]}} = Blobs.list_public(@did, 1)
  end

  test "blob restriction survives ownership deletion and imported missing references", c do
    alias Atoll.{Blobs, CAR, CBOR, CID, Commit, MST, TID}
    bytes = "withdrawn bytes"
    {:ok, blob} = Blobs.stage(@did, bytes, "text/plain")
    text = blob["ref"]["$link"]
    subject = %{"$type" => "com.atproto.admin.defs#repoBlobRef", "did" => @did, "cid" => text}
    path = "com.example.record/withdrawn"

    {:ok, _} =
      Repositories.apply_writes(
        @did,
        [{:put, path, %{"$type" => "com.example.record", "blob" => blob}}],
        c.key
      )

    update(c, %{"subject" => subject, "takedown" => %{"applied" => true}}) |> json_response(200)
    {:ok, head} = Repositories.apply_writes(@did, [{:delete, path}], c.key)
    refute Repo.get_by(Atoll.Blobs.Blob, did: @did, cid: CID.create(bytes, :raw))
    assert {:error, :blob_taken_down} = Blobs.stage(@did, bytes, "text/plain")

    assert (auth(c.conn)
            |> get(@get, %{did: @did, blob: text})
            |> json_response(200))["takedown"]["applied"]

    record =
      CBOR.encode!(%{
        "$type" => "com.example.record",
        "blob" => Map.put(blob, "ref", %CBOR.Link{cid: CID.create(bytes, :raw)})
      })

    record_cid = CID.create(record, :dag_cbor)
    {:ok, tree} = MST.new(%{path => record_cid})
    {:ok, rev} = TID.next(head.rev)
    {:ok, commit} = Commit.create(@did, tree.root, rev, c.key)

    {:ok, car} =
      CAR.encode(
        [commit.cid],
        tree.blocks |> Map.put(record_cid, record) |> Map.put(commit.cid, commit.bytes)
      )

    assert {:ok, _} = Repositories.import_archive(@did, car, head.head)
    assert {:ok, %{blobs: []}} = Atoll.Blobs.Missing.list(c.pair.access_jwt, 10, nil)
    update(c, %{"subject" => subject, "takedown" => %{"applied" => false}}) |> json_response(200)
    assert {:ok, %{blobs: [%{cid: ^text}]}} = Atoll.Blobs.Missing.list(c.pair.access_jwt, 10, nil)
    assert {:ok, _} = Blobs.stage(@did, bytes, "text/plain")
    assert {:ok, %{bytes: ^bytes}} = Blobs.get_public(@did, CID.create(bytes, :raw))
  end

  test "blob moderation validates target, CID, metadata and availability independently of account status",
       c do
    alias Atoll.{Blobs, CID}
    bytes = "staged moderation"
    {:ok, _} = Blobs.stage(@did, bytes, "text/plain")
    cid = CID.create(bytes, :raw)
    text = CID.to_base32(cid)
    subject = %{"$type" => "com.atproto.admin.defs#repoBlobRef", "did" => @did, "cid" => text}

    for params <- [
          %{
            "subject" =>
              Map.put(subject, "cid", CID.to_base32(CID.create("wrong codec", :dag_cbor)))
          },
          %{"subject" => subject, "deactivated" => %{"applied" => true}},
          %{
            "subject" =>
              Map.put(
                subject,
                "recordUri",
                "at://did:web:other.example.com/com.example.record/one"
              )
          },
          %{
            "subject" => subject,
            "takedown" => %{"applied" => true, "ref" => String.duplicate("x", 2001)}
          }
        ],
        do: assert(update(c, params) |> json_response(400))

    unknown = Map.put(subject, "cid", CID.to_base32(CID.create("unknown", :raw)))

    assert %{"error" => "NotFound"} =
             update(c, %{"subject" => unknown, "takedown" => %{"applied" => true}})
             |> json_response(400)

    assert Repo.aggregate(Atoll.Blobs.Takedown, :count) == 0
    {:ok, _} = Repositories.set_status(@did, :takendown)

    update(c, %{
      "subject" => Map.put(subject, "recordUri", "at://#{@did}/com.example.record/one"),
      "takedown" => %{"applied" => true}
    })
    |> json_response(200)

    {:ok, _} = Repositories.set_status(@did, :active)
    assert {:error, :blob_taken_down} = Blobs.stage(@did, bytes, "text/plain")
    # Staged cleanup may reclaim bytes but cannot clear the moderation marker.
    Repo.get_by!(Atoll.Blobs.Blob, did: @did, cid: cid)
    |> Ecto.Changeset.change(staged_at: DateTime.add(DateTime.utc_now(), -100_000))
    |> Repo.update!()

    assert {:ok, 1} = Atoll.Blobs.Cleanup.expire_staged()
    assert {:error, :blob_taken_down} = Blobs.stage(@did, bytes, "text/plain")

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        Atoll.Accounts.SubjectStatus.update(%{
                          "subject" => subject,
                          "takedown" => %{"applied" => false}
                        })

               Repo.rollback(:cancelled)
             end)

    assert {:error, :blob_taken_down} = Blobs.stage(@did, bytes, "text/plain")
    update(c, %{"subject" => subject, "takedown" => %{"applied" => false}}) |> json_response(200)
    assert {:ok, _} = Blobs.stage(@did, bytes, "text/plain")
  end

  defp auth(conn),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("admin:" <> @secret))

  defp update(c, params),
    do:
      auth(c.conn)
      |> put_req_header("content-type", "application/json")
      |> post(@update, Jason.encode!(Map.merge(%{"subject" => @subject}, params)))
end
