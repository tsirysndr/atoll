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
         {:ok, allow} <- allow_headers(get_req_header(conn, "access-control-request-headers")) do
      conn
      |> put_resp_header("access-control-allow-methods", method)
      |> put_resp_header("access-control-allow-headers", allow)
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

  # A wildcard origin cannot carry cookies, so requested header names are
  # reflected (like the reference PDS) rather than restricted to a fixed list.
  # The default set is advertised when the browser requests no specific headers.
  def allow_headers([]), do: {:ok, Enum.join(@headers, ", ")}

  def allow_headers([value]) when byte_size(value) <= 4096 and value != "" do
    names =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if String.valid?(value) and names != [] and Enum.all?(names, &token?/1),
      do: {:ok, Enum.join(names, ", ")},
      else: :error
  end

  def allow_headers(_), do: :error

  # RFC 7230 header field-name token characters, so a reflected value can never
  # inject a second header or control bytes.
  defp token?(name), do: Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, name)
end
