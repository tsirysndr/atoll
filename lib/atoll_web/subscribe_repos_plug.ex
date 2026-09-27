defmodule AtollWeb.SubscribeReposPlug do
  @moduledoc "Handles the raw subscription request before HEAD/method rewriting and body parsing."
  import Plug.Conn
  @behaviour Plug
  @path "/xrpc/com.atproto.sync.subscribeRepos"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _) do
    path = "/" <> Enum.map_join(conn.path_info, "/", &URI.decode/1)
    if path == @path, do: subscribe(conn), else: conn
  end

  defp subscribe(conn) do
    cond do
      conn.method != "GET" ->
        conn |> put_resp_header("allow", "GET") |> error(405, "MethodNotAllowed")

      get_req_header(conn, "upgrade") == [] ->
        conn |> put_resp_header("upgrade", "websocket") |> error(426, "UpgradeRequired")

      true ->
        case AtollWeb.StreamConnections.reserve(conn.remote_ip) do
          {:ok, lease} ->
            upgrade(conn, parse_cursor(conn.query_string), lease)

          {:error, :full} ->
            conn |> put_resp_header("retry-after", "1") |> error(429, "RateLimitExceeded")

          {:error, :unavailable} ->
            conn |> put_resp_header("retry-after", "1") |> error(503, "ServiceUnavailable")
        end
    end
  rescue
    WebSockAdapter.UpgradeError -> error(conn, 400, "InvalidRequest")
  end

  defp upgrade(conn, cursor, lease) do
    conn
    |> WebSockAdapter.upgrade(AtollWeb.RepoStreamSocket, %{cursor: cursor, lease: lease},
      timeout: 60_000,
      max_frame_size: 65_536,
      compress: false
    )
    |> halt()
  rescue
    error ->
      AtollWeb.StreamConnections.release(lease)
      reraise error, __STACKTRACE__
  end

  defp parse_cursor(query) do
    case Atoll.Lexicon.Query.decode("com.atproto.sync.subscribeRepos", query) do
      {:ok, %{"cursor" => value}} ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> {:error, :invalid_cursor}
        end

      {:ok, _} ->
        {:ok, nil}

      {:error, _} ->
        {:error, :invalid_cursor}
    end
  end

  defp error(conn, status, name) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: name}))
    |> halt()
  end
end
