defmodule AtollWeb.XRPCCORS do
  @moduledoc "Public-origin XRPC access using explicit Authorization headers, never cookies."
  import Plug.Conn

  @headers ~w(accept accept-language authorization dpop content-type atproto-proxy atproto-accept-labelers)
  @exposed "atproto-content-labelers, atproto-repo-rev, retry-after, dpop-nonce, ratelimit-limit, ratelimit-remaining, ratelimit-reset, www-authenticate"

  def headers(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-expose-headers", @exposed)
  end

  def preflight?(conn) do
    conn.method == "OPTIONS" and get_req_header(conn, "origin") != [] and
      get_req_header(conn, "access-control-request-method") != []
  end

  def preflight(conn, method) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("vary", "access-control-request-method, access-control-request-headers")

    with [_origin] <- get_req_header(conn, "origin"),
         [^method] <- get_req_header(conn, "access-control-request-method"),
         true <- allowed_headers?(get_req_header(conn, "access-control-request-headers")) do
      conn
      |> put_resp_header("access-control-allow-methods", method)
      |> put_resp_header("access-control-allow-headers", Enum.join(@headers, ", "))
      |> put_resp_header("access-control-max-age", "600")
      |> send_resp(204, "")
      |> halt()
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{error: "InvalidRequest", message: "Invalid CORS preflight."})
        )
        |> halt()
    end
  end

  defp allowed_headers?([]), do: true

  defp allowed_headers?([value]) when byte_size(value) <= 1024 do
    String.valid?(value) and
      Enum.all?(String.split(value, ","), fn header ->
        String.downcase(String.trim(header)) in @headers
      end)
  end

  defp allowed_headers?(_), do: false
end
