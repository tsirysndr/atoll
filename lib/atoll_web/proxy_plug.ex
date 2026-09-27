defmodule AtollWeb.ProxyPlug do
  @moduledoc "Authenticated XRPC service proxying with explicit targets and an optional default AppView."
  @behaviour Plug
  import Plug.Conn
  alias Atoll.Proxy.{Target, Transport}

  def init(opts), do: opts

  def appview_from_env!(value) when value in [nil, ""], do: nil

  def appview_from_env!(value) do
    case Target.parse(value) do
      {:ok, _} -> value
      _ -> raise ArgumentError, "ATOLL_APPVIEW_PROXY must be a DID#service reference or empty"
    end
  end

  @doc false
  def candidate?(conn, nsid, local?) do
    get_req_header(conn, "atproto-proxy") != [] or proxy_preflight?(conn) or
      (not local? and String.starts_with?(nsid, "app.bsky.") and
         not is_nil(Application.get_env(:atoll, :appview_proxy)))
  end

  defp proxy_preflight?(conn) do
    AtollWeb.XRPCCORS.preflight?(conn) and
      Enum.any?(get_req_header(conn, "access-control-request-headers"), fn value ->
        byte_size(value) <= 1024 and
          Enum.any?(
            String.split(value, ","),
            &(String.downcase(String.trim(&1)) == "atproto-proxy")
          )
      end)
  end

  @doc false
  def validate_route(conn, nsid) do
    cond do
      conn.request_path != "/xrpc/" <> nsid ->
        error(conn, 400, "InvalidRequest", "Use the canonical XRPC path.")

      conn.method in ["GET", "POST"] ->
        conn

      AtollWeb.XRPCCORS.preflight?(conn) ->
        case get_req_header(conn, "access-control-request-method") do
          [method] when method in ["GET", "POST"] -> AtollWeb.XRPCCORS.preflight(conn, method)
          _ -> error(conn, 400, "InvalidRequest", "Invalid proxy preflight method.")
        end

      true ->
        conn
        |> put_resp_header("allow", "GET, POST")
        |> error(405, "MethodNotAllowed", "Proxy requests require GET or POST.")
    end
  end

  def call(conn, _) do
    if conn.private[:atoll_proxy] do
      ["xrpc", nsid] = conn.path_info
      proxy(conn, nsid)
    else
      conn
    end
  end

  defp proxy(conn, nsid) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")

    opts = Application.get_env(:atoll, :proxy_options, [])
    oauth? = AtollWeb.OAuthResource.attempt?(conn)

    with {:ok, audience} <- audience(conn),
         {:ok, _} <- Target.parse(audience),
         {:ok, {prepared, jwt}} <-
           authorize(conn, audience, nsid, oauth?, fn ->
             prepare(conn, audience, opts)
           end),
         {:ok, response} <-
           Transport.send(
             prepared.target,
             if(conn.method == "GET", do: :get, else: :post),
             nsid,
             conn.query_string,
             conn.req_headers,
             prepared.body,
             jwt,
             opts
           ) do
      response.headers
      |> Enum.reduce(prepared.conn, fn {name, values}, acc ->
        put_resp_header(acc, name, Enum.join(values, ", "))
      end)
      |> send_resp(response.status, response.body)
      |> halt()
    else
      {:error, reason} -> failure(conn, reason, oauth?)
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] ->
      error(conn, 503, "ServiceUnavailable", "Proxy authorization is temporarily unavailable.")
  end

  defp audience(conn) do
    case get_req_header(conn, "atproto-proxy") do
      [] -> {:ok, Application.get_env(:atoll, :appview_proxy)}
      [value] -> {:ok, value}
      _ -> {:error, :invalid_proxy_target}
    end
  end

  defp authorize(conn, audience, nsid, true, prepare),
    do: AtollWeb.OAuthResource.with_proxy(conn, audience, nsid, prepare)

  defp authorize(conn, audience, nsid, false, prepare) do
    with {:ok, token} <- AtollWeb.BearerToken.get(conn),
         do: Atoll.Accounts.ServiceAuth.with_proxy(token, audience, nsid, prepare)
  end

  defp prepare(conn, audience, opts) do
    with {:ok, body, conn} <-
           read_body(conn, length: 2 * 1024 * 1024 + 1, read_length: 65_536, read_timeout: 5000),
         :ok <- body_size(body),
         true <- conn.method == "POST" or body == "" do
      case Target.resolve(audience, opts) do
        {:ok, target} -> {:ok, %{target: target, body: body, conn: conn}}
        {:error, _} -> {:error, :proxy_resolution_failed}
      end
    else
      {:more, _, _} -> {:error, :proxy_request_too_large}
      false -> {:error, :invalid_proxy_request}
      {:error, :proxy_request_too_large} = error -> error
      {:error, _} -> {:error, :proxy_body_unavailable}
    end
  end

  defp body_size(body) when byte_size(body) <= 2 * 1024 * 1024, do: :ok
  defp body_size(_), do: {:error, :proxy_request_too_large}

  defp failure(conn, reason, _) when reason in [:invalid_proxy_target, :invalid_proxy_request],
    do: error(conn, 400, "InvalidRequest", "Invalid proxy request.")

  defp failure(conn, :proxy_request_too_large, _),
    do: error(conn, 413, "PayloadTooLarge", "Proxy request exceeds 2 MiB.")

  defp failure(conn, :proxy_body_unavailable, _),
    do: error(conn, 408, "RequestTimeout", "Could not read the proxy request body.")

  defp failure(conn, :proxy_timeout, _),
    do: error(conn, 504, "UpstreamTimeout", "The service did not respond in time.")

  defp failure(conn, reason, _)
       when reason in [
              :proxy_resolution_failed,
              :proxy_response_too_large,
              :proxy_content_encoding,
              :proxy_response_status,
              :proxy_unavailable
            ],
       do: error(conn, 502, "UpstreamFailure", "The service request failed.")

  defp failure(conn, reason, _)
       when reason in [:key_vault_unconfigured, :key_not_found, :key_decryption_failed],
       do: conn |> AtollWeb.XRPCFallback.call({:error, reason}) |> halt()

  defp failure(conn, reason, true), do: AtollWeb.OAuthResource.error(conn, reason)

  defp failure(conn, reason, false),
    do: conn |> AtollWeb.XRPCFallback.call({:error, reason}) |> halt()

  defp error(conn, status, name, message) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: name, message: message}))
    |> halt()
  end
end
