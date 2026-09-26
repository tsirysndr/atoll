defmodule AtollWeb.AdminAuth do
  @moduledoc false
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")

    case Atoll.Accounts.AdminAuth.authenticate(get_req_header(conn, "authorization")) do
      :ok ->
        conn

      {:error, :admin_not_configured} ->
        error(conn, 503, "ServiceUnavailable", "Administration is not configured.")

      _ ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="atoll-admin", charset="UTF-8"))
        |> error(401, "AuthRequired", "Administrative authentication required.")
    end
  end

  defp error(conn, status, error, message),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{error: error, message: message}))
      |> halt()
end
