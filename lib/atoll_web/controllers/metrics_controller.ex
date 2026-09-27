defmodule AtollWeb.MetricsController do
  use AtollWeb, :controller

  def show(conn, _) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    if Application.get_env(:atoll, :metrics_enabled, false) == true do
      conn = AtollWeb.AdminAuth.call(conn, [])

      if conn.halted do
        conn
      else
        conn
        |> put_resp_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
        |> send_resp(200, Atoll.Metrics.render())
      end
    else
      send_resp(conn, 404, "Not found")
    end
  catch
    :exit, _ ->
      conn
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(503, "Metrics unavailable")
  end
end
