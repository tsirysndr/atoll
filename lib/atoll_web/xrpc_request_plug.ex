defmodule AtollWeb.XRPCRequestPlug do
  @moduledoc "Bounds XRPC request volume and validates routing before parsing or method rewriting."
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def rate_limit_from_env!(nil), do: 3000

  def rate_limit_from_env!(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..100_000 -> limit
      _ -> raise ArgumentError, "ATOLL_XRPC_RATE_LIMIT must be an integer from 1 to 100000"
    end
  end

  def call(conn, _opts) do
    case Enum.map(conn.path_info, &URI.decode/1) do
      ["xrpc" | segments] ->
        conn = AtollWeb.XRPCCORS.headers(conn)
        limit = Application.get_env(:atoll, :xrpc_rate_limit, 3000)

        case Atoll.Accounts.SessionLimiter.check({:xrpc, conn.remote_ip}, limit) do
          :ok ->
            route(conn, segments)

          {:error, seconds} ->
            :telemetry.execute([:atoll, :xrpc, :rate_limit], %{count: 1}, %{})

            conn
            |> put_resp_header("retry-after", Integer.to_string(seconds))
            |> error(429, "RateLimitExceeded", "Too many XRPC requests.")
        end

      _ ->
        conn
    end
  end

  defp route(conn, [nsid]), do: validate(conn, nsid)
  defp route(conn, _), do: error(conn, 400, "InvalidRequest", "Invalid XRPC path.")

  defp validate(conn, nsid) do
    if Atoll.Syntax.nsid?(nsid) do
      case expected_method(nsid) do
        nil ->
          error(conn, 501, "MethodNotImplemented", "XRPC method is not implemented.")

        method when method == conn.method ->
          conn

        method ->
          if AtollWeb.XRPCCORS.preflight?(conn) do
            AtollWeb.XRPCCORS.preflight(conn, method)
          else
            conn
            |> put_resp_header("allow", method)
            |> error(405, "MethodNotAllowed", "Unsupported request method.")
          end
      end
    else
      error(conn, 400, "InvalidRequest", "Invalid XRPC method identifier.")
    end
  end

  defp expected_method("com.atproto.sync.subscribeRepos"), do: "GET"

  defp expected_method(nsid) do
    path = "/xrpc/" <> nsid

    # Consult the router at runtime so adding an endpoint cannot silently leave
    # this boundary's method inventory out of sync with Phoenix's routes.
    Enum.find_value(AtollWeb.Router.__routes__(), fn route ->
      if route.path == path, do: route.verb |> Atom.to_string() |> String.upcase()
    end)
  end

  defp error(conn, status, name, message) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: name, message: message}))
    |> halt()
  end
end
