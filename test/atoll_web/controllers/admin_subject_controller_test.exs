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

    cid = Atoll.CID.create("record", :dag_cbor) |> Atoll.CID.to_base32()

    for subject <- [
          %{
            "$type" => "com.atproto.repo.strongRef",
            "uri" => "at://#{@did}/com.example.record/one",
            "cid" => cid
          },
          %{"$type" => "com.atproto.admin.defs#repoBlobRef", "did" => @did, "cid" => cid}
        ] do
      assert %{
               "error" => "InvalidRequest",
               "message" => "Only local repository subjects are supported."
             } =
               update(c, %{"subject" => subject, "takedown" => %{"applied" => true}})
               |> json_response(400)
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

  defp auth(conn),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("admin:" <> @secret))

  defp update(c, params),
    do:
      auth(c.conn)
      |> put_req_header("content-type", "application/json")
      |> post(@update, Jason.encode!(Map.merge(%{"subject" => @subject}, params)))
end
