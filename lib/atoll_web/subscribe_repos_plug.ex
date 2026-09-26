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
        cursor = parse_cursor(conn.query_string)

        conn
        |> WebSockAdapter.upgrade(AtollWeb.RepoStreamSocket, cursor,
          timeout: 60_000,
          max_frame_size: 65_536,
          compress: false
        )
        |> halt()
    end
  rescue
    WebSockAdapter.UpgradeError -> error(conn, 400, "InvalidRequest")
  end

  defp parse_cursor(query) do
    values = for {"cursor", value} <- URI.query_decoder(query), do: value

    case values do
      [] ->
        {:ok, nil}

      [value] ->
        if Regex.match?(~r/\A[0-9]{1,16}\z/, value) do
          case Integer.parse(value) do
            {n, ""} when n <= 9_007_199_254_740_991 -> {:ok, n}
            _ -> {:error, :invalid_cursor}
          end
        else
          {:error, :invalid_cursor}
        end

      _ ->
        {:error, :invalid_cursor}
    end
  rescue
    ArgumentError -> {:error, :invalid_cursor}
  end

  defp error(conn, status, name) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: name}))
    |> halt()
  end
end
