defmodule AtollWeb.SessionRequestPlug do
  @moduledoc "Session method, body-size, and rate checks before the general body parser."
  import Plug.Conn
  @prefix "/xrpc/com.atproto.server."
  @procedures [
    @prefix <> "requestEmailConfirmation",
    @prefix <> "confirmEmail",
    @prefix <> "createAccount",
    @prefix <> "createSession",
    @prefix <> "refreshSession",
    @prefix <> "deleteSession",
    @prefix <> "activateAccount",
    @prefix <> "deactivateAccount"
  ]
  @queries [
    @prefix <> "getSession",
    @prefix <> "checkAccountStatus",
    @prefix <> "getServiceAuth",
    "/xrpc/com.atproto.repo.listMissingBlobs",
    "/xrpc/com.atproto.identity.getRecommendedDidCredentials"
  ]
  @parser Plug.Parsers.init(
            parsers: [:json],
            json_decoder: Jason,
            length: 4096,
            read_length: 4096,
            read_timeout: 5_000
          )

  def init(opts), do: opts

  def call(conn, _opts) do
    # Match Phoenix's decoded path segments, including percent-encoded route spellings.
    path = "/" <> Enum.map_join(conn.path_info, "/", &URI.decode/1)
    if path in @procedures or path in @queries, do: session(conn, path), else: conn
  end

  defp session(conn, path) do
    method = if path in @queries, do: "GET", else: "POST"

    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")

    if conn.method == method do
      {bucket, limit} =
        if path in [@prefix <> "createSession", @prefix <> "createAccount"],
          do: {:login, 20},
          else: {:session, 300}

      case Atoll.Accounts.SessionLimiter.check({bucket, conn.remote_ip}, limit) do
        :ok ->
          parse(conn, path)

        {:error, seconds} ->
          conn
          |> put_resp_header("retry-after", Integer.to_string(seconds))
          |> error(429, "RateLimitExceeded", "Too many session requests.")
      end
    else
      conn
      |> put_resp_header("allow", method)
      |> error(405, "MethodNotAllowed", "Unsupported request method.")
    end
  end

  defp parse(conn, path)
       when path in [
              @prefix <> "createSession",
              @prefix <> "createAccount",
              @prefix <> "deactivateAccount",
              @prefix <> "confirmEmail"
            ] do
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
      error(conn, 413, "InvalidRequest", "Session request body is too large.")

    Plug.Parsers.ParseError ->
      error(conn, 400, "InvalidRequest", "Invalid JSON body.")
  end

  # These methods have no input body. Bound any unexpected body before the general parser.
  defp parse(conn, _path) do
    case read_body(conn, length: 4096, read_length: 4096, read_timeout: 5_000) do
      {:ok, "", conn} -> %{conn | body_params: %{}}
      {:ok, _, conn} -> error(conn, 400, "InvalidRequest", "This method has no request body.")
      {:more, _, conn} -> error(conn, 413, "InvalidRequest", "Session request body is too large.")
      {:error, _} -> error(conn, 400, "InvalidRequest", "Unable to read request body.")
    end
  end

  defp error(conn, status, code, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: code, message: message}))
    |> halt()
  end
end
