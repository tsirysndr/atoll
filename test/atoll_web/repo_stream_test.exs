defmodule AtollWeb.RepoStreamTest do
  use AtollWeb.ConnCase, async: true
  alias Atoll.{CBOR, Repositories, SigningKey}
  alias Atoll.Repositories.{Events, EventEncoder}
  alias AtollWeb.RepoStreamSocket, as: Socket
  @path "/xrpc/com.atproto.sync.subscribeRepos"
  @did "did:plc:stream"

  test "plain requests require upgrade and non-GET methods are rejected", %{conn: conn} do
    assert json_response(get(conn, @path), 426)["error"] == "UpgradeRequired"

    for method <- [:post, :put, :delete, :head] do
      response = dispatch(conn, @endpoint, method, @path, nil)
      assert response.status == 405
      assert get_resp_header(response, "allow") == ["GET"]
    end
  end

  test "upgrade preserves cursor and rejects malformed handshakes", %{conn: conn} do
    response = conn |> handshake() |> get(@path <> "?cursor=0")
    assert response.state == :upgraded
    assert_receive {_, :upgrade, {:websocket, {Socket, %{cursor: {:ok, 0}, lease: lease}, _}}}
    AtollWeb.StreamConnections.release(lease)
    bad = conn |> put_req_header("upgrade", "websocket") |> get(@path)
    assert json_response(bad, 400)["error"] == "InvalidRequest"
    owner = self()

    refute Enum.any?(:sys.get_state(AtollWeb.StreamConnections).entries, fn {_, entry} ->
             entry.owner == owner
           end)
  end

  test "invalid and duplicate cursors are rejected inside the upgraded stream", %{conn: conn} do
    for query <- [
          "cursor=-1",
          "cursor=no",
          "cursor=1.2",
          "cursor=9007199254740992",
          "cursor=1&cursor=2",
          "cursor=1&%63ursor=2",
          "cursor[]=1",
          "cursor=%FF",
          "extension=%GG",
          "extension[a]=1",
          "extension=" <> String.duplicate("a", 32_769),
          Enum.map_join(1..257, "&", &"key#{&1}=value")
        ] do
      assert (conn |> handshake() |> get(@path <> "?" <> query)).state == :upgraded

      assert_receive {_, :upgrade,
                      {:websocket, {Socket, %{cursor: {:error, :invalid_cursor}} = cursor, _}}}

      assert {:stop, :normal, 1000, {:binary, frame}, state} = Socket.init(cursor)
      Socket.terminate(:normal, state)
      assert error_body(frame)["error"] == "InvalidRequest"
    end
  end

  test "streams stop after their quota manager exits" do
    manager = start_supervised!({AtollWeb.StreamConnections, name: nil})
    {:ok, lease} = AtollWeb.StreamConnections.reserve(:test, manager)
    {:ok, state} = Socket.init(%{cursor: {:ok, nil}, lease: lease})
    monitor = state.quota_monitor
    stop_supervised!(AtollWeb.StreamConnections)
    assert_receive {:DOWN, ^monitor, :process, ^manager, _} = message
    assert {:stop, {:shutdown, :restart}, ^state} = Socket.handle_info(message, state)
    Socket.terminate(:shutdown, state)
    assert {:stop, :normal, 1013, %{}} = Socket.init(%{cursor: {:ok, nil}, lease: lease})
  end

  test "replay is exclusive and live polling sees subsequent commits" do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, [event]} = Events.list_after(0)
    {:ok, state} = Socket.init({:ok, 0})
    assert_receive :drain
    assert {:push, {:binary, frame}, state} = Socket.handle_info(:drain, state)
    assert {:ok, ^frame} = EventEncoder.encode(event)
    assert state.cursor == event.seq
    assert_receive :drain
    assert {:ok, state} = Socket.handle_info(:drain, state)
    Socket.terminate(:normal, state)

    {:ok, _} = Repositories.set_status(@did, :suspended)
    assert {:push, {:binary, _}, state} = Socket.handle_info(:drain, state)
    assert state.cursor > event.seq
    Socket.terminate(:normal, state)
    assert {:ok, :idle} = Events.next_frame(state.cursor)
  end

  test "no cursor starts at the current position and future cursors close" do
    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    latest = Events.latest_seq()
    {:ok, state} = Socket.init({:ok, nil})
    assert state.cursor == latest
    Socket.terminate(:normal, state)
    assert {:stop, :normal, 1000, {:binary, frame}, _} = Socket.init({:ok, latest + 1})
    assert error_body(frame)["error"] == "FutureCursor"
  end

  test "inactive repository data is skipped while account status remains visible" do
    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    first = Events.latest_seq()
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert {:ok, {:skip, ^first}} = Events.next_frame(0)
    assert {:ok, {:frame, seq, _}} = Events.next_frame(first)
    assert seq > first
    {:ok, _} = Repositories.set_status(@did, :active)
    assert {:ok, {:frame, ^first, _}} = Events.next_frame(0)
  end

  test "backlog counts rows rather than sequence gaps and closes slow consumers" do
    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    assert Events.backlog_exceeded?(0, 0)
    refute Events.backlog_exceeded?(0, 1)

    row = %{
      did: @did,
      kind: :account,
      payload: CBOR.encode!(%{"active" => true}),
      time: DateTime.utc_now()
    }

    List.duplicate(row, 10_000)
    |> Enum.chunk_every(1000)
    |> Enum.each(&Atoll.Repo.insert_all(Atoll.Repositories.Event, &1))

    {:ok, state} = Socket.init({:ok, 0})
    assert_receive :drain
    assert {:stop, :normal, 1000, {:binary, frame}, _} = Socket.handle_info(:drain, state)
    assert error_body(frame)["error"] == "ConsumerTooSlow"
  end

  test "client data is ignored and idle connections receive periodic pings" do
    state = %{cursor: Events.latest_seq(), idle: 29}
    assert {:ok, ^state} = Socket.handle_in({"ignored", opcode: :text}, state)
    assert {:push, {:ping, ""}, next} = Socket.handle_info(:drain, state)
    Socket.terminate(:normal, next)
  end

  defp handshake(conn) do
    %{conn | req_headers: [{"host", conn.host} | conn.req_headers]}
    |> put_req_header("connection", "upgrade")
    |> put_req_header("upgrade", "websocket")
    |> put_req_header("sec-websocket-version", "13")
    |> put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
  end

  defp error_body(<<0xA1, 0x62, "op", 0x20, body::binary>>) do
    {:ok, value} = CBOR.decode(body)
    value
  end
end
