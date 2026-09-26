defmodule AtollWeb.OAuthRequestPlug do
  @moduledoc "PAR and token HTTP boundary before general parsing, logging, or method rewriting."
  @behaviour Plug
  import Plug.Conn
  alias Atoll.OAuth.{DPoP, Form, Nonce, PAR, CodeExchange, Refresh}
  @limit 49_152
  @allowed_headers ~w(content-type dpop)

  def init(opts), do: opts

  def call(conn, _opts) do
    case Enum.map(conn.path_info, &URI.decode/1) do
      ["oauth", "par"] -> handle(put_private(conn, :oauth_endpoint, :oauth_par))
      ["oauth", "token"] -> handle(put_private(conn, :oauth_endpoint, :oauth_token))
      _ -> conn
    end
  end

  defp handle(conn) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-expose-headers", "dpop-nonce, retry-after")

    # Always include a fresh server nonce when configured, including errors.
    case Nonce.issue(:authorization) do
      {:ok, nonce} ->
        conn = put_resp_header(conn, "dpop-nonce", nonce)

        case Atoll.Accounts.SessionLimiter.check(
               {conn.private.oauth_endpoint, conn.remote_ip},
               20
             ) do
          :ok ->
            route(conn)

          {:error, seconds} ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(seconds))
            |> error(429, "temporarily_unavailable")
        end

      _ ->
        error(conn, 503, "temporarily_unavailable")
    end
  end

  defp route(%{request_path: path} = conn) when path not in ["/oauth/par", "/oauth/token"],
    do: error(conn, 400, "invalid_request")

  defp route(%{method: "OPTIONS"} = conn), do: preflight(conn)
  defp route(%{method: "POST"} = conn), do: parse(conn)

  defp route(conn),
    do: conn |> put_resp_header("allow", "POST, OPTIONS") |> error(405, "invalid_request")

  defp parse(conn) do
    cond do
      conn.query_string != "" ->
        error(conn, 400, "invalid_request")

      get_req_header(conn, "authorization") != [] ->
        reject_authorization(conn)

      get_req_header(conn, "content-encoding") not in [[], ["identity"]] ->
        error(conn, 415, "invalid_request")

      not form_content_type?(get_req_header(conn, "content-type")) ->
        error(conn, 415, "invalid_request")

      not length_allowed?(get_req_header(conn, "content-length")) ->
        error(conn, 413, "invalid_request")

      true ->
        read(conn)
    end
  end

  defp reject_authorization(%{private: %{oauth_endpoint: :oauth_token}} = conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme | _] <- String.split(header, " ", parts: 2),
         true <- Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/, scheme) do
      conn
      |> put_resp_header("www-authenticate", scheme <> " realm=\"oauth\"")
      |> error(401, "invalid_client")
    else
      _ -> error(conn, 400, "invalid_client")
    end
  end

  defp reject_authorization(conn), do: error(conn, 400, "invalid_client")

  defp read(conn) do
    case read_body(conn, length: @limit, read_length: @limit + 1, read_timeout: 5000) do
      {:ok, body, conn} when byte_size(body) <= @limit ->
        case Form.decode(body) do
          {:ok, params} -> admit(conn, params)
          _ -> error(conn, 400, "invalid_request")
        end

      {:more, _, conn} ->
        error(conn, 413, "invalid_request")

      {:ok, _, conn} ->
        error(conn, 413, "invalid_request")

      {:error, _} ->
        error(conn, 400, "invalid_request")
    end
  end

  defp admit(conn, params) do
    headers = get_req_header(conn, "dpop")
    # An initial nonce challenge must not consume the confidential assertion or
    # trigger metadata fetches. Full signature/replay admission follows this check.
    with {:ok, nonce} <- DPoP.peek_nonce(headers),
         {:ok, _} <- Nonce.verify(nonce, :authorization) do
      opts =
        Application.get_env(:atoll, :oauth_transport_options, [])
        |> Keyword.take([:request, :lookup])

      case execute(conn.private.oauth_endpoint, params, headers, opts) do
        {:ok, result} ->
          reply(conn, if(conn.private.oauth_endpoint == :oauth_par, do: 201, else: 200), result)

        {:error, reason} ->
          oauth_error(conn, reason)
      end
    else
      {:error, reason} -> oauth_error(conn, reason)
    end
  end

  defp execute(:oauth_par, params, headers, opts), do: PAR.push(params, headers, opts)

  defp execute(:oauth_token, %{"grant_type" => "authorization_code"} = params, headers, opts),
    do: CodeExchange.exchange(params, headers, opts)

  defp execute(:oauth_token, %{"grant_type" => "refresh_token"} = params, headers, opts),
    do: Refresh.exchange(params, headers, opts)

  defp execute(:oauth_token, %{"grant_type" => grant}, _, _) when grant != "",
    do: {:error, :unsupported_grant_type}

  defp execute(:oauth_token, _, _, _), do: {:error, :invalid_request}

  defp oauth_error(conn, reason) when reason in [:invalid_grant, :unsupported_grant_type],
    do: error(conn, 400, Atom.to_string(reason))

  defp oauth_error(conn, :use_dpop_nonce), do: error(conn, 400, "use_dpop_nonce")

  defp oauth_error(conn, reason) when reason in [:invalid_dpop_proof, :dpop_replayed],
    do: error(conn, 400, "invalid_dpop_proof")

  defp oauth_error(conn, :invalid_scope), do: error(conn, 400, "invalid_scope")

  defp oauth_error(conn, reason)
       when reason in [
              :invalid_client,
              :invalid_client_keys,
              :invalid_client_metadata,
              :invalid_client_assertion,
              :client_assertion_replayed
            ],
       do: error(conn, 400, "invalid_client")

  defp oauth_error(conn, reason)
       when reason in [
              :oauth_refresh_store_full,
              :oauth_refresh_store_unavailable,
              :oauth_session_limit,
              :oauth_exchange_store_unavailable,
              :oauth_par_store_full,
              :oauth_par_store_unavailable,
              :oauth_assertion_store_full,
              :oauth_assertion_store_unavailable,
              :oauth_proof_store_full,
              :oauth_proof_store_unavailable,
              :oauth_nonce_unconfigured
            ],
       do: conn |> put_resp_header("retry-after", "1") |> error(503, "temporarily_unavailable")

  defp oauth_error(conn, _), do: error(conn, 400, "invalid_request")

  defp preflight(conn) do
    conn =
      put_resp_header(
        conn,
        "vary",
        "access-control-request-method, access-control-request-headers"
      )

    with [_] <- get_req_header(conn, "origin"),
         ["POST"] <- get_req_header(conn, "access-control-request-method"),
         true <- headers_allowed?(get_req_header(conn, "access-control-request-headers")) do
      conn
      |> put_resp_header("access-control-allow-methods", "POST")
      |> put_resp_header("access-control-allow-headers", "content-type, dpop")
      |> put_resp_header("access-control-max-age", "600")
      |> send_resp(204, "")
      |> halt()
    else
      _ -> error(conn, 400, "invalid_request")
    end
  end

  defp headers_allowed?([]), do: true

  defp headers_allowed?([value]) when byte_size(value) <= 1024,
    do:
      String.valid?(value) and
        Enum.all?(
          String.split(value, ","),
          &(String.downcase(String.trim(&1)) in @allowed_headers)
        )

  defp headers_allowed?(_), do: false

  defp form_content_type?([value]) do
    case Plug.Conn.Utils.media_type(value) do
      {:ok, "application", "x-www-form-urlencoded", params} ->
        String.downcase(Map.get(params, "charset", "utf-8")) == "utf-8"

      _ ->
        false
    end
  end

  defp form_content_type?(_), do: false
  defp length_allowed?([]), do: true

  defp length_allowed?([value]) do
    case Integer.parse(value) do
      {length, ""} when length in 0..@limit -> true
      _ -> false
    end
  end

  defp length_allowed?(_), do: false
  defp error(conn, status, name), do: reply(conn, status, %{error: name})

  defp reply(conn, status, body),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
      |> halt()
end
