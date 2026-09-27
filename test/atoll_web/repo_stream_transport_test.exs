defmodule AtollWeb.RepoStreamTransportTest do
  use Atoll.DataCase, async: false
  alias Atoll.{CBOR, Repositories, SigningKey}
  alias Atoll.Repositories.{EventEncoder, Events}

  setup do
    server = start_supervised!({Bandit, plug: AtollWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{port: port}
  end

  test "real WebSocket upgrades, replays, delivers new events, and resumes", %{port: port} do
    did = "did:plc:transport"
    {:ok, _} = Repositories.create(did, SigningKey.generate())
    {:ok, [created]} = Events.list_after(0)
    {:ok, expected} = EventEncoder.encode(created)
    socket = connect(port, "0")
    assert {2, ^expected} = receive_frame(socket)

    {:ok, _} = Repositories.set_status(did, :suspended)
    {:ok, [status]} = Events.list_after(created.seq)
    {:ok, expected_status} = EventEncoder.encode(status)
    assert {2, ^expected_status} = receive_frame(socket)
    :gen_tcp.close(socket)

    resumed = connect(port, Integer.to_string(created.seq))
    assert {2, ^expected_status} = receive_frame(resumed)
    :gen_tcp.close(resumed)
  end

  test "future cursors receive an error binary frame followed by close", %{port: port} do
    socket = connect(port, Integer.to_string(Events.latest_seq() + 1))
    assert {2, <<0xA1, 0x62, "op", 0x20, body::binary>>} = receive_frame(socket)
    assert {:ok, %{"error" => "FutureCursor"}} = CBOR.decode(body)
    assert {8, <<1000::16>>} = receive_frame(socket)
    :gen_tcp.close(socket)
  end

  test "malformed subscription parameters send an error frame and clean close", %{port: port} do
    for query <- ["0&cursor=1", "%FF", "0&extension=%GG", "0&extension[x]=y"] do
      socket = connect(port, query)
      assert {2, <<0xA1, 0x62, "op", 0x20, body::binary>>} = receive_frame(socket)
      assert {:ok, %{"error" => "InvalidRequest"}} = CBOR.decode(body)
      assert {8, <<1000::16>>} = receive_frame(socket)
      :gen_tcp.close(socket)
    end
  end

  test "expired cursor sends a real info frame before retained replay", %{port: port} do
    did = "did:plc:transportretention"
    {:ok, _} = Repositories.create(did, SigningKey.generate())
    first = Events.latest_seq()
    {:ok, _} = Repositories.set_status(did, :deactivated)
    old_time = DateTime.add(DateTime.utc_now(), -7200, :second)
    Repo.update_all(Atoll.Repositories.Event, set: [time: old_time])
    {:ok, _} = Repositories.set_status(did, :active)
    {:ok, %{floor: floor}} = Atoll.Repositories.EventRetention.prune(1000, 3600)
    {:ok, [retained]} = Events.list_after(floor)
    {:ok, expected} = EventEncoder.encode(retained)
    socket = connect(port, Integer.to_string(first))
    assert {2, notice} = receive_frame(socket)
    header = CBOR.encode!(%{"op" => 1, "t" => "#info"})
    size = byte_size(header)
    assert <<^header::binary-size(size), body::binary>> = notice
    assert {:ok, %{"name" => "OutdatedCursor"}} = CBOR.decode(body)
    assert {2, ^expected} = receive_frame(socket)
    :gen_tcp.close(socket)
    oldest = connect(port, "0")
    assert {2, ^expected} = receive_frame(oldest)
    :gen_tcp.close(oldest)
  end

  test "live connection quotas reject upgrades until the socket releases its slot", %{port: port} do
    previous = Application.fetch_env!(:atoll, :firehose_max_connections_per_ip)
    Application.put_env(:atoll, :firehose_max_connections_per_ip, 1)
    on_exit(fn -> Application.put_env(:atoll, :firehose_max_connections_per_ip, previous) end)
    socket = connect(port, "0")
    state = :sys.get_state(AtollWeb.StreamConnections)
    [%{owner: owner}] = Map.values(state.entries)
    monitor = Process.monitor(owner)

    {:ok, rejected} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :http_bin], 2000)

    on_exit(fn -> :gen_tcp.close(rejected) end)

    :ok =
      :gen_tcp.send(
        rejected,
        "GET /xrpc/com.atproto.sync.subscribeRepos HTTP/1.1\r\nHost: localhost\r\nX-Forwarded-For: 8.8.8.8\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
      )

    assert {:ok, {:http_response, {1, 1}, 429, _}} = :gen_tcp.recv(rejected, 0, 2000)
    headers = receive_headers(rejected, [])

    assert Enum.any?(headers, fn {name, value} ->
             String.downcase(to_string(name)) == "retry-after" and value == "1"
           end)

    :gen_tcp.close(socket)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 2000
    assert :sys.get_state(AtollWeb.StreamConnections).entries == %{}
    resumed = connect(port, "0")
    :gen_tcp.close(resumed)
  end

  test "firehose environment limits override configuration only when explicitly set" do
    variables = [
      {"ATOLL_FIREHOSE_MAX_CONNECTIONS", :firehose_max_connections},
      {"ATOLL_FIREHOSE_MAX_CONNECTIONS_PER_IP", :firehose_max_connections_per_ip}
    ]

    for {variable, _} <- variables do
      previous = System.get_env(variable)

      on_exit(fn ->
        if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
      end)

      System.delete_env(variable)
    end

    config = Config.Reader.read!("config/runtime.exs", env: :test, target: :host)

    for {variable, key} <- variables do
      refute Keyword.has_key?(config[:atoll], key)
      System.put_env(variable, "7")

      assert Config.Reader.read!("config/runtime.exs", env: :test, target: :host)[:atoll][key] ==
               7

      System.put_env(variable, "0")

      assert_raise ArgumentError, fn ->
        Config.Reader.read!("config/runtime.exs", env: :test, target: :host)
      end

      System.delete_env(variable)
    end
  end

  defp connect(port, cursor) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :http_bin], 2000)

    on_exit(fn -> :gen_tcp.close(socket) end)

    :ok =
      :gen_tcp.send(socket, [
        "GET /xrpc/com.atproto.sync.subscribeRepos?cursor=",
        cursor,
        " HTTP/1.1\r\n",
        "Host: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n",
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
      ])

    assert {:ok, {:http_response, {1, 1}, 101, _}} = :gen_tcp.recv(socket, 0, 2000)
    headers = receive_headers(socket, [])

    assert Enum.any?(headers, fn {name, value} ->
             String.downcase(to_string(name)) == "sec-websocket-accept" and
               value == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
           end)

    :ok = :inet.setopts(socket, packet: :raw)
    socket
  end

  defp receive_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, :http_eoh} -> acc
      {:ok, {:http_header, _, name, _, value}} -> receive_headers(socket, [{name, value} | acc])
    end
  end

  defp receive_frame(socket) do
    assert {:ok, <<1::1, 0::3, opcode::4, 0::1, length::7>>} = :gen_tcp.recv(socket, 2, 2000)

    size =
      case length do
        126 ->
          {:ok, <<n::16>>} = :gen_tcp.recv(socket, 2, 2000)
          n

        127 ->
          {:ok, <<n::64>>} = :gen_tcp.recv(socket, 8, 2000)
          n

        n ->
          n
      end

    assert {:ok, payload} = :gen_tcp.recv(socket, size, 2000)
    {opcode, payload}
  end
end
