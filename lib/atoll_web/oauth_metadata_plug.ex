defmodule AtollWeb.OAuthMetadataPlug do
  @moduledoc "Public OAuth metadata served before request parsing, without cookies or credentials."
  @behaviour Plug
  import Plug.Conn
  alias Atoll.OAuth.ServerMetadata
  @paths ~w(/.well-known/oauth-authorization-server /.well-known/oauth-protected-resource)
  @headers ~w(accept accept-language content-type)

  def init(opts), do: opts

  def call(conn, _) do
    path = "/" <> Enum.map_join(conn.path_info, "/", &URI.decode/1)

    if path in @paths do
      conn =
        conn
        |> put_resp_header("access-control-allow-origin", "*")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("cache-control", "no-store")

      cond do
        conn.request_path != path or conn.query_string != "" ->
          reply(conn, 400, %{error: "invalid_request"})

        conn.method not in ["GET", "HEAD", "OPTIONS"] ->
          conn
          |> put_resp_header("allow", "GET, HEAD, OPTIONS")
          |> reply(405, %{error: "invalid_request"})

        true ->
          serve(conn, path)
      end
    else
      conn
    end
  end

  defp serve(conn, path) do
    result =
      if path == "/.well-known/oauth-authorization-server",
        do: ServerMetadata.authorization(),
        else: ServerMetadata.resource()

    case result do
      {:ok, metadata} ->
        origin = metadata[:issuer] || metadata[:resource]

        if String.downcase(conn.host) == URI.parse(origin).host do
          if conn.method == "OPTIONS",
            do: preflight(conn),
            else:
              conn
              |> put_resp_header("cache-control", "public, max-age=300")
              |> reply(200, metadata)
        else
          reply(conn, 404, %{error: "not_found"})
        end

      _ ->
        reply(conn, 503, %{error: "temporarily_unavailable"})
    end
  end

  defp preflight(conn) do
    conn =
      conn
      |> put_resp_header("allow", "GET, HEAD, OPTIONS")
      |> put_resp_header("vary", "access-control-request-method, access-control-request-headers")

    case {get_req_header(conn, "origin"), get_req_header(conn, "access-control-request-method")} do
      {[], []} ->
        conn |> send_resp(204, "") |> halt()

      {[_origin], [method]} when method in ["GET", "HEAD"] ->
        if headers_allowed?(get_req_header(conn, "access-control-request-headers")) do
          conn
          |> put_resp_header("access-control-allow-methods", "GET, HEAD")
          |> put_resp_header("access-control-allow-headers", Enum.join(@headers, ", "))
          |> put_resp_header("access-control-max-age", "600")
          |> send_resp(204, "")
          |> halt()
        else
          reply(conn, 400, %{error: "invalid_request"})
        end

      _ ->
        reply(conn, 400, %{error: "invalid_request"})
    end
  end

  defp headers_allowed?([]), do: true

  defp headers_allowed?([value]) when byte_size(value) <= 1024,
    do:
      String.valid?(value) and
        Enum.all?(String.split(value, ","), &(String.downcase(String.trim(&1)) in @headers))

  defp headers_allowed?(_), do: false

  defp reply(conn, status, value) do
    body = Jason.encode!(value)

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-length", Integer.to_string(byte_size(body)))
    |> send_resp(status, if(conn.method == "HEAD", do: "", else: body))
    |> halt()
  end
end
