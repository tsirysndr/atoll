defmodule AtollWeb.OAuthResource do
  @moduledoc "OAuth resource response headers and read adapter; only explicitly integrated routes authorize access."
  @behaviour Plug
  import Plug.Conn
  alias Atoll.OAuth.{Nonce, Resource}

  def init(opts), do: opts

  def call(conn, _) do
    if match?(["xrpc" | _], Enum.map(conn.path_info, &URI.decode/1)) and attempt?(conn) do
      conn =
        conn
        |> AtollWeb.XRPCCORS.headers()
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("pragma", "no-cache")

      case Nonce.issue(:resource) do
        {:ok, nonce} -> put_resp_header(conn, "dpop-nonce", nonce)
        _ -> failure(conn, :oauth_nonce_unconfigured)
      end
    else
      conn
    end
  end

  def attempt?(conn) do
    get_req_header(conn, "dpop") != [] or
      Enum.any?(get_req_header(conn, "authorization"), fn value ->
        Regex.match?(~r/\A(?:DPoP(?:\s|$)|Bearer +atoll_access_)/i, value)
      end)
  end

  def read(conn, reader, opts \\ []) do
    case read_result(conn, reader, opts) do
      {:ok, result} ->
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(result))

      {:error, conn} ->
        conn
    end
  end

  @doc "Run a read callback under OAuth authorization locks, preserving its domain result."
  def read_result(conn, reader, opts \\ []) do
    with {:ok, token} <- token(get_req_header(conn, "authorization")),
         {:ok, result} <-
           Resource.read(
             token,
             get_req_header(conn, "dpop"),
             AtollWeb.Endpoint.url() <> conn.request_path,
             reader,
             opts
           ) do
      {:ok, result}
    else
      {:error, reason} -> {:error, failure(conn, reason)}
    end
  end

  def prepare_write(conn) do
    with {:ok, token} <- token(get_req_header(conn, "authorization")),
         do:
           Resource.prepare_write(
             token,
             get_req_header(conn, "dpop"),
             AtollWeb.Endpoint.url() <> conn.request_path
           )
  end

  def error(conn, reason), do: failure(conn, reason)

  defp token([header]) when byte_size(header) <= 128 do
    case Regex.run(~r/\ADPoP +(atoll_access_[A-Za-z0-9_-]{43})\z/i, header) do
      [_, token] -> {:ok, token}
      _ -> {:error, :invalid_token}
    end
  end

  defp token([_]), do: {:error, :invalid_token}
  defp token([]), do: {:error, :invalid_token}
  defp token(_), do: {:error, :invalid_request}

  defp failure(conn, reason)
       when reason in [
              :oauth_nonce_unconfigured,
              :oauth_resource_store_unavailable,
              :oauth_proof_store_full,
              :oauth_proof_store_unavailable
            ] do
    conn |> put_resp_header("retry-after", "1") |> reply(503, "temporarily_unavailable")
  end

  defp failure(conn, reason) do
    {status, error} =
      case reason do
        :use_dpop_nonce -> {401, "use_dpop_nonce"}
        :invalid_dpop_proof -> {401, "invalid_dpop_proof"}
        :dpop_replayed -> {401, "invalid_dpop_proof"}
        :insufficient_scope -> {403, "insufficient_scope"}
        :invalid_request -> {400, "invalid_request"}
        _ -> {401, "invalid_token"}
      end

    conn
    |> put_resp_header("www-authenticate", "DPoP error=\"#{error}\", algs=\"ES256\"")
    |> reply(status, error)
  end

  defp reply(conn, status, error),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{error: error}))
      |> halt()
end
