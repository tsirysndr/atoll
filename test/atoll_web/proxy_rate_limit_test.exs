defmodule AtollWeb.ProxyRateLimitTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.Accounts.SessionLimiter

  setup %{conn: conn} do
    previous =
      Map.new([:trusted_proxies, :xrpc_rate_limit], &{&1, Application.fetch_env(:atoll, &1)})

    Application.put_env(
      :atoll,
      :trusted_proxies,
      AtollWeb.ClientIP.parse_trusted_proxies!("10.71.0.0/16")
    )

    Application.put_env(:atoll, :xrpc_rate_limit, 2)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    id = rem(System.unique_integer([:positive]), 65_536)

    %{
      conn: %{conn | remote_ip: {10, 71, div(id, 256), rem(id, 256)}},
      client: {10, 72, div(id, 256), rem(id, 256)}
    }
  end

  test "clients behind the same trusted proxy have separate general budgets", c do
    client = c.client |> Tuple.to_list() |> Enum.join(".")
    first = put_req_header(c.conn, "x-forwarded-for", client)

    for _ <- 1..2,
        do: assert(get(first, "/xrpc/com.atproto.server.describeServer") |> json_response(200))

    assert get(first, "/xrpc/com.atproto.server.describeServer") |> json_response(429)
    second = put_req_header(c.conn, "x-forwarded-for", "10.73.1.1")
    assert get(second, "/xrpc/com.atproto.server.describeServer") |> json_response(200)
  end

  test "the derived client address applies to specialized limits too", c do
    Application.put_env(:atoll, :xrpc_rate_limit, 1000)
    for _ <- 1..20, do: SessionLimiter.check({:login, c.client}, 20)
    client = c.client |> Tuple.to_list() |> Enum.join(".")

    conn =
      c.conn
      |> put_req_header("x-forwarded-for", client)
      |> put_req_header("content-type", "application/json")

    assert post(conn, "/xrpc/com.atproto.server.createSession", %{}) |> json_response(429)
    assert get(conn, "/xrpc/com.atproto.server.describeServer") |> json_response(200)
  end
end
