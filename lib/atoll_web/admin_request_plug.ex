defmodule AtollWeb.AdminRequestPlug do
  @moduledoc "Bounds and authenticates administrative requests before JSON parsing."
  import Plug.Conn

  @paths [
    "/xrpc/com.atproto.server.createInviteCode",
    "/xrpc/com.atproto.server.createInviteCodes",
    "/xrpc/com.atproto.admin.disableInviteCodes"
  ]
  @parser Plug.Parsers.init(
            parsers: [:json],
            json_decoder: Jason,
            length: 16_384,
            read_length: 16_384,
            read_timeout: 5000
          )
  def init(opts), do: opts

  def call(conn, _) do
    path = "/" <> Enum.map_join(conn.path_info, "/", &URI.decode/1)

    if path in @paths do
      conn =
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("pragma", "no-cache")

      if conn.method == "POST" do
        case Atoll.Accounts.SessionLimiter.check({:admin, conn.remote_ip}, 60) do
          :ok ->
            conn = AtollWeb.AdminAuth.call(conn, [])
            if conn.halted, do: conn, else: parse(conn)

          {:error, seconds} ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(seconds))
            |> error(429, "RateLimitExceeded", "Too many administrative requests.")
        end
      else
        conn
        |> put_resp_header("allow", "POST")
        |> error(405, "MethodNotAllowed", "Expected POST.")
      end
    else
      conn
    end
  end

  defp parse(conn) do
    case get_req_header(conn, "content-type") do
      [type] ->
        case Plug.Conn.Utils.media_type(type) do
          {:ok, "application", "json", _} -> Plug.Parsers.call(conn, @parser)
          _ -> error(conn, 415, "InvalidRequest", "Expected application/json.")
        end

      _ ->
        error(conn, 415, "InvalidRequest", "Expected application/json.")
    end
  rescue
    Plug.Parsers.RequestTooLargeError ->
      error(conn, 413, "InvalidRequest", "Administrative request is too large.")

    Plug.Parsers.ParseError ->
      error(conn, 400, "InvalidRequest", "Invalid JSON body.")
  end

  defp error(conn, status, error, message),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{error: error, message: message}))
      |> halt()
end
