defmodule AtollWeb.HealthController do
  use AtollWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
