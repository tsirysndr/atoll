defmodule AtollWeb.AccountBrowserPlug do
  @moduledoc "Bounded account forms and an isolated encrypted browser session before general parsers."
  @behaviour Plug
  import Plug.Conn
  @paths ~w(/account/login /account/sessions /account/sessions/revoke /account/logout)

  def init(opts), do: opts

  def call(conn, _) do
    path = "/" <> Enum.map_join(conn.path_info, "/", &URI.decode/1)

    if path in @paths do
      conn =
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("pragma", "no-cache")
        |> put_resp_header("referrer-policy", "no-referrer")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("x-frame-options", "DENY")
        |> put_resp_header(
          "content-security-policy",
          "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
        )

      cond do
        conn.request_path != path ->
          fail(conn, 400, "Invalid request.")

        conn.method not in methods(path) ->
          conn
          |> put_resp_header("allow", Enum.join(methods(path), ", "))
          |> fail(405, "Method not allowed.")

        true ->
          limited(conn, path)
      end
    else
      conn
    end
  end

  defp methods(path) when path in ["/account/login", "/account/sessions"],
    do: if(path == "/account/login", do: ["GET", "POST"], else: ["GET"])

  defp methods(_), do: ["POST"]

  defp limited(conn, path) do
    login? = path == "/account/login" and conn.method == "POST"
    bucket = if login?, do: :account_login, else: :account_browser
    limit = if login?, do: 10, else: 100

    case Atoll.Accounts.SessionLimiter.check({bucket, conn.remote_ip}, limit) do
      :ok ->
        parse(conn, path)

      {:error, seconds} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(seconds))
        |> fail(429, "Try again later.")
    end
  end

  defp parse(%{method: "GET"} = conn, path) do
    if byte_size(conn.query_string) <= 1024,
      do: dispatch(fetch_query_params(conn), path),
      else: fail(conn, 400, "Invalid request.")
  end

  defp parse(conn, path) do
    with true <- conn.query_string == "",
         true <- get_req_header(conn, "content-encoding") in [[], ["identity"]],
         [type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "x-www-form-urlencoded", _} <- Plug.Conn.Utils.media_type(type),
         {:ok, body, conn} <- read_body(conn, length: 8192, read_length: 8193, read_timeout: 5000),
         {:ok, params} <- Atoll.OAuth.Form.decode(body) do
      dispatch(%{conn | body_params: params, params: params}, path)
    else
      {:more, _, conn} -> fail(conn, 413, "Form is too large.")
      _ -> fail(conn, 400, "Invalid form.")
    end
  end

  defp dispatch(conn, path) do
    session =
      Plug.Session.init(
        store: :cookie,
        key: "_atoll_account",
        signing_salt: "account-sign-v1",
        encryption_salt: "account-encrypt-v1",
        same_site: "Lax",
        http_only: true,
        secure: URI.parse(AtollWeb.Endpoint.url()).scheme == "https",
        max_age: 3600
      )

    conn = conn |> Plug.Session.call(session) |> fetch_session() |> expire_session()
    conn = Plug.CSRFProtection.call(conn, Plug.CSRFProtection.init([]))
    AtollWeb.AccountController.dispatch(conn, path) |> halt()
  rescue
    Plug.CSRFProtection.InvalidCSRFTokenError ->
      fail(conn, 403, "The form expired. Reload the page and try again.")
  end

  defp expire_session(conn) do
    expires = get_session(conn, :account_expires_at)

    if get_session(conn, :account_access) &&
         (not is_integer(expires) or expires <= System.system_time(:second)),
       do: conn |> clear_session() |> configure_session(renew: true),
       else: conn
  end

  defp fail(conn, status, message),
    do: AtollWeb.AccountController.message(conn, status, message) |> halt()
end
