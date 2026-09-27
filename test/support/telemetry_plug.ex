defmodule Atoll.TestTelemetryPlug do
  @moduledoc false
  require Logger
  def init(opts), do: opts

  def call(conn, _opts) do
    Atoll.Repo.query!("SELECT 1")
    Logger.warning("telemetry integration check")
    Plug.Conn.send_resp(conn, if(conn.request_path == "/error", do: 503, else: 200), "ok")
  end
end
