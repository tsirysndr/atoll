defmodule AtollWeb.XRPCRequestPlug do
  @moduledoc "Validates XRPC routing before body parsing and HTTP method rewriting."
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Enum.map(conn.path_info, &URI.decode/1) do
      ["xrpc", nsid] ->
        validate(AtollWeb.XRPCCORS.headers(conn), nsid)

      ["xrpc" | _] ->
        error(AtollWeb.XRPCCORS.headers(conn), 400, "InvalidRequest", "Invalid XRPC path.")

      _ ->
        conn
    end
  end

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
