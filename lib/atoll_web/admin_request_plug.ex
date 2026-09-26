defmodule AtollWeb.AdminRequestPlug do
  @moduledoc "Bounds and authenticates administrative requests before JSON parsing."
  import Plug.Conn

  @paths [
    "/xrpc/com.atproto.server.createInviteCode",
    "/xrpc/com.atproto.server.createInviteCodes",
    "/xrpc/com.atproto.admin.disableInviteCodes",
    "/xrpc/com.atproto.admin.disableAccountInvites",
    "/xrpc/com.atproto.admin.enableAccountInvites",
    "/xrpc/com.atproto.admin.updateSubjectStatus"
  ]
  @queries [
    "/xrpc/com.atproto.admin.getInviteCodes",
    "/xrpc/com.atproto.admin.getSubjectStatus",
    "/xrpc/com.atproto.admin.getAccountInfo",
    "/xrpc/com.atproto.admin.getAccountInfos"
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

    if path in @paths or path in @queries do
      conn =
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("pragma", "no-cache")

      method = if path in @queries, do: "GET", else: "POST"

      if conn.method == method do
        case Atoll.Accounts.SessionLimiter.check({:admin, conn.remote_ip}, 60) do
          :ok ->
            conn = AtollWeb.AdminAuth.call(conn, [])
            if conn.halted, do: conn, else: parse(conn, method)

          {:error, seconds} ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(seconds))
            |> error(429, "RateLimitExceeded", "Too many administrative requests.")
        end
      else
        conn
        |> put_resp_header("allow", method)
        |> error(405, "MethodNotAllowed", "Unsupported administrative method.")
      end
    else
      conn
    end
  end

  defp parse(conn, "GET") do
    case read_body(conn, length: 16_384, read_length: 16_384, read_timeout: 5000) do
      {:ok, "", conn} ->
        %{conn | body_params: %{}}

      {:more, _, conn} ->
        error(conn, 413, "InvalidRequest", "Administrative request is too large.")

      _ ->
        error(conn, 400, "InvalidRequest", "This query has no request body.")
    end
  end

  defp parse(conn, "POST") do
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
