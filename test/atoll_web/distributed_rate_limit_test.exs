defmodule AtollWeb.DistributedRateLimitTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.Accounts.SessionLimiter

  setup %{conn: conn} do
    previous =
      Map.new([:rate_limit_backend, :xrpc_rate_limit], &{&1, Application.fetch_env(:atoll, &1)})

    Application.put_env(:atoll, :rate_limit_backend, :postgres)
    Application.put_env(:atoll, :xrpc_rate_limit, 2)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    %{conn: %{conn | remote_ip: {10, 74, 0, 1}}}
  end

  test "HTTP guards use the shared store for both general and specialized budgets", c do
    for _ <- 1..2,
        do: assert(get(c.conn, "/xrpc/com.atproto.server.describeServer") |> json_response(200))

    assert get(c.conn, "/xrpc/com.atproto.server.describeServer") |> json_response(429)
    Application.put_env(:atoll, :xrpc_rate_limit, 1000)
    for _ <- 1..20, do: assert(:ok = SessionLimiter.check({:login, c.conn.remote_ip}, 20))

    result =
      c.conn
      |> put_req_header("content-type", "application/json")
      |> post("/xrpc/com.atproto.server.createSession", %{})

    assert json_response(result, 429)["error"] == "RateLimitExceeded"
    assert get(c.conn, "/health") |> json_response(200)
  end
end
