defmodule AtollWeb.ClientIPTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  alias AtollWeb.ClientIP

  test "untrusted peers cannot change their address using any forwarded header" do
    conn =
      connection({203, 0, 113, 10}, "8.8.8.8")
      |> put_req_header("forwarded", "for=9.9.9.9")
      |> put_req_header("cf-connecting-ip", "1.1.1.1")

    result = ClientIP.call(conn, trusted_proxies: ranges("10.0.0.0/8"))
    assert result.remote_ip == conn.remote_ip
    assert result.private.atoll_peer_ip == conn.remote_ip
  end

  test "walks from the nearest proxy and stops at the first untrusted hop" do
    conn = connection({10, 0, 0, 2}, "1.1.1.1, 203.0.113.7, 10.0.0.1")
    result = ClientIP.call(conn, trusted_proxies: ranges("10.0.0.0/24"))
    assert result.remote_ip == {203, 0, 113, 7}
    assert result.private.atoll_peer_ip == {10, 0, 0, 2}
    # Even a syntactically valid leftmost spoof cannot cross an untrusted hop.
    result =
      ClientIP.call(connection({10, 0, 0, 2}, "8.8.8.8, 192.0.2.8"),
        trusted_proxies: ranges("10.0.0.0/24")
      )

    assert result.remote_ip == {192, 0, 2, 8}
  end

  test "supports exact addresses, IPv6 CIDRs, and canonicalizes mapped IPv4" do
    peer = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

    result =
      ClientIP.call(connection(peer, "2001:4860:4860::8888"),
        trusted_proxies: ranges("2001:db8::/32")
      )

    assert result.remote_ip == {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}
    mapped = {0, 0, 0, 0, 0, 65535, 0x0A00, 1}

    result =
      ClientIP.call(connection(mapped, "::ffff:192.0.2.5"), trusted_proxies: ranges("10.0.0.1"))

    assert result.remote_ip == {192, 0, 2, 5}
    assert result.private.atoll_peer_ip == mapped
    assert ranges("::ffff:10.0.0.0/120") == ranges("10.0.0.0/24")

    assert ClientIP.call(connection(mapped, "8.8.8.8"), trusted_proxies: []).remote_ip ==
             {10, 0, 0, 1}

    assert ClientIP.call(connection({10, 0, 1, 1}, "8.8.8.8"),
             trusted_proxies: ranges("10.0.0.0/24")
           ).remote_ip == {10, 0, 1, 1}
  end

  test "ambiguous, oversized, and malformed chains fall back to the direct peer" do
    peer = {10, 0, 0, 1}
    opts = [trusted_proxies: ranges("10.0.0.1")]

    for header <- [
          "",
          "unknown",
          "8.8.8.8,",
          "8.8.8.8:123",
          "[2001:db8::1]",
          "127.1",
          "8.8.8.8, garbage",
          String.duplicate("x", 2049),
          Enum.join(List.duplicate("8.8.8.8", 33), ",")
        ] do
      assert ClientIP.call(connection(peer, header), opts).remote_ip == peer
    end

    conn = connection(peer, "8.8.8.8")
    conn = %{conn | req_headers: [{"x-forwarded-for", "9.9.9.9"} | conn.req_headers]}
    assert ClientIP.call(conn, opts).remote_ip == peer
    conn = %{conn | req_headers: []}
    assert ClientIP.call(conn, opts).remote_ip == peer
  end

  test "configuration rejects hostnames, invalid masks, empty entries, and excess ranges" do
    assert ranges(nil) == []
    assert ranges("") == []
    assert ranges(" 10.0.0.1 , 10.0.0.1/32 ") == ranges("10.0.0.1")

    for value <- [
          "proxy.example.com",
          "10.0.0.1/33",
          "::/129",
          "::ffff:10.0.0.0/80",
          "10.0.0.1/-1",
          "10.0.0.1/1x",
          "10.0.0.1/",
          "10.0.0.1,",
          "10.0.0.1/1/2",
          Enum.join(List.duplicate("10.0.0.1", 129), ",")
        ] do
      assert_raise ArgumentError, fn -> ranges(value) end
    end
  end

  defp ranges(text), do: ClientIP.parse_trusted_proxies!(text)

  defp connection(peer, header),
    do:
      %{Plug.Test.conn(:get, "/") | remote_ip: peer} |> put_req_header("x-forwarded-for", header)
end
