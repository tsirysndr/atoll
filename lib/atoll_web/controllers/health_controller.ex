defmodule AtollWeb.HealthController do
  use AtollWeb, :controller

  def show(conn, _params) do
    conn |> put_resp_header("cache-control", "no-store") |> json(%{status: "ok"})
  end

  def ready(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case Atoll.Readiness.check() do
      :ready -> json(conn, %{status: "ok"})
      :unavailable -> conn |> put_status(:service_unavailable) |> json(%{status: "unavailable"})
    end
  end
end
