defmodule AtollWeb.MetricsControllerTest do
  use AtollWeb.ConnCase, async: false
  @password String.duplicate("m", 32)
  setup do
    for key <- [:metrics_enabled, :admin_password] do
      previous = Application.fetch_env(:atoll, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end)
    end

    Application.put_env(:atoll, :admin_password, @password)
    :ok
  end

  test "disabled endpoint stays hidden even with operator credentials", %{conn: conn} do
    Application.put_env(:atoll, :metrics_enabled, false)
    assert get(conn, "/metrics").status == 404
    assert conn |> authenticated() |> get("/metrics") |> response(404) == "Not found"
  end

  test "enabled endpoint requires operator authentication and serves uncached Prometheus text", %{
    conn: conn
  } do
    Application.put_env(:atoll, :metrics_enabled, true)
    assert get(conn, "/metrics").status == 401

    assert conn
           |> put_req_header("authorization", "Bearer invalid")
           |> get("/metrics")
           |> response(401)

    reply = conn |> authenticated() |> put_req_header("accept", "text/plain") |> get("/metrics")
    assert response(reply, 200) =~ "# TYPE atoll_http_requests_total counter\n"
    assert get_resp_header(reply, "content-type") == ["text/plain; version=0.0.4; charset=utf-8"]
    assert get_resp_header(reply, "cache-control") == ["no-store"]
    Application.delete_env(:atoll, :admin_password)
    assert conn |> authenticated() |> get("/metrics") |> response(503)
  end

  test "environment configuration accepts only explicit booleans" do
    assert Atoll.Metrics.enabled_from_env!("true")
    refute Atoll.Metrics.enabled_from_env!("false")

    for invalid <- ["1", "TRUE", "", nil],
        do: assert_raise(ArgumentError, fn -> Atoll.Metrics.enabled_from_env!(invalid) end)
  end

  defp authenticated(conn),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("admin:" <> @password))
end
