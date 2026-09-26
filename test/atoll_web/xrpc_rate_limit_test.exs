defmodule AtollWeb.XRPCRateLimitTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.Accounts.SessionLimiter
  alias AtollWeb.XRPCRequestPlug

  setup %{conn: conn} do
    prior = Application.fetch_env(:atoll, :xrpc_rate_limit)
    Application.put_env(:atoll, :xrpc_rate_limit, 3)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:atoll, :xrpc_rate_limit, value)
        :error -> Application.delete_env(:atoll, :xrpc_rate_limit)
      end
    end)

    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 69, div(id, 256), rem(id, 256)}}}
  end

  test "all XRPC methods share the peer budget before parsing and keep CORS on rejection", c do
    assert get(c.conn, "/xrpc/com.atproto.server.describeServer") |> json_response(200)
    assert get(c.conn, "/xrpc/com.example.unknown") |> json_response(501)

    assert c.conn
           |> put_req_header("content-type", "application/json")
           |> post("/xrpc/com.atproto.server.createSession", "{")
           |> json_response(400)

    result =
      c.conn
      |> put_req_header("origin", "https://client.example.com")
      |> get("/%78rpc/com.atproto.sync.%67etRepo?bad=%ZZ")

    assert json_response(result, 429)["error"] == "RateLimitExceeded"
    assert get_resp_header(result, "access-control-allow-origin") == ["*"]
    assert get_resp_header(result, "cache-control") == ["no-store"]
    [seconds] = get_resp_header(result, "retry-after")
    assert String.to_integer(seconds) in 1..300
    assert get(c.conn, "/health") |> json_response(200)
    assert get(c.conn, "/") |> response(200)
  end

  test "forwarding headers cannot change the bucket, but a different peer has its own budget",
       c do
    for _ <- 1..3, do: assert(:ok = SessionLimiter.check({:xrpc, c.conn.remote_ip}, 3))

    conn =
      c.conn
      |> put_req_header("x-forwarded-for", "8.8.8.8")
      |> put_req_header("forwarded", "for=9.9.9.9")

    assert get(conn, "/xrpc/com.atproto.server.describeServer") |> json_response(429)
    {_, _, a, b} = c.conn.remote_ip

    assert get(%{conn | remote_ip: {10, 70, a, b}}, "/xrpc/com.atproto.server.describeServer")
           |> json_response(200)
  end

  test "malformed paths, wrong methods, and preflights are counted", c do
    assert get(c.conn, "/xrpc") |> json_response(400)
    assert post(c.conn, "/xrpc/com.atproto.server.describeServer") |> json_response(405)

    result =
      c.conn
      |> put_req_header("origin", "https://client.example.com")
      |> put_req_header("access-control-request-method", "GET")
      |> options("/xrpc/com.atproto.server.describeServer")

    assert response(result, 204) == ""
    assert get(c.conn, "/xrpc/com.atproto.server.describeServer") |> json_response(429)
  end

  test "specialized budgets remain stricter than the general budget", c do
    Application.put_env(:atoll, :xrpc_rate_limit, 1000)
    for _ <- 1..20, do: assert(:ok = SessionLimiter.check({:login, c.conn.remote_ip}, 20))

    result =
      c.conn
      |> put_req_header("content-type", "application/json")
      |> post("/xrpc/com.atproto.server.createSession", %{})

    assert json_response(result, 429)["error"] == "RateLimitExceeded"
    assert get(c.conn, "/xrpc/com.atproto.server.describeServer") |> json_response(200)
  end

  test "configuration has a bounded default and rejects malformed or disabled budgets" do
    assert XRPCRequestPlug.rate_limit_from_env!(nil) == 3000
    assert XRPCRequestPlug.rate_limit_from_env!("1") == 1
    assert XRPCRequestPlug.rate_limit_from_env!("100000") == 100_000

    for value <- ["0", "-1", "100001", "1.5", "10x", "", "unlimited"] do
      assert_raise ArgumentError, fn -> XRPCRequestPlug.rate_limit_from_env!(value) end
    end
  end
end
