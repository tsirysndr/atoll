defmodule AtollWeb.HealthController do
  use AtollWeb, :controller

  def show(conn, _params) do
    conn |> put_resp_header("cache-control", "no-store") |> json(%{status: "ok"})
  end

  def xrpc(conn, _params) do
    version = "atoll " <> to_string(Application.spec(:atoll, :vsn))
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Atoll.Readiness.check() do
      :ready ->
        json(conn, %{version: version})

      :unavailable ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{version: version, error: "Service Unavailable"})
    end
  end

  def ready(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Atoll.Readiness.check() do
      :ready -> json(conn, %{status: "ok"})
      :unavailable -> conn |> put_status(:service_unavailable) |> json(%{status: "unavailable"})
    end
  end
end
