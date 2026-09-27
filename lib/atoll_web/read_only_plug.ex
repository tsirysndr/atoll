defmodule AtollWeb.ReadOnlyPlug do
  @moduledoc """
  Rejects mutating requests while this node runs in read-only maintenance mode.

  Public and password-session reads, the firehose, health and metrics stay
  available. Every POST is refused, and so are OAuth-credentialed reads, because
  proof admission persists replay state. Background writers are not started in
  this mode; in-flight work on other nodes is outside this plug's control.
  """
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def enabled_from_env!(value) do
    case value do
      nil -> false
      "false" -> false
      "true" -> true
      _ -> raise ArgumentError, "ATOLL_READ_ONLY must be true or false"
    end
  end

  def call(conn, _opts) do
    if Application.get_env(:atoll, :read_only, false) and mutating?(conn) do
      conn = if xrpc?(conn), do: AtollWeb.XRPCCORS.headers(conn), else: conn

      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("retry-after", "30")
      |> put_resp_content_type("application/json")
      |> send_resp(
        503,
        Jason.encode!(%{
          error: "ServiceUnavailable",
          message: "The server is in read-only maintenance mode."
        })
      )
      |> halt()
    else
      conn
    end
  end

  defp mutating?(conn) do
    conn.method in ["POST", "PUT", "PATCH", "DELETE"] or
      (xrpc?(conn) and AtollWeb.OAuthResource.attempt?(conn))
  end

  defp xrpc?(conn), do: match?(["xrpc" | _], conn.path_info)
end
