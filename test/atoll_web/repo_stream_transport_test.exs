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
