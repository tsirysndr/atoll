defmodule AtollWeb.AccountBrowserPlug do
  @moduledoc "Bounded account forms and an isolated encrypted browser session before general parsers."
  @behaviour Plug
  import Plug.Conn

  @passkey_paths ~w(/account/passkeys /account/passkeys/register/begin /account/passkeys/register/finish /account/passkeys/login/begin /account/passkeys/login/finish /account/passkeys/revoke)
  @paths @passkey_paths ++
           ~w(/account/signup /account/login /account/reset /account/sessions /account/sessions/revoke /account/logout /oauth/authorize /account/security /account/security/begin /account/security/confirm /account/security/recovery /account/security/disable)

  def init(opts), do: opts

  def call(conn, _) do
    path = "/" <> Enum.map_join(conn.path_info, "/", &URI.decode/1)

    # The reset link from the email carries its token in the path, so the
    # route is a prefix rather than one of the fixed pages.
    route = if reset_path?(path), do: "/account/reset", else: path

    if route in @paths do
      conn =
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("pragma", "no-cache")
        |> put_resp_header("referrer-policy", "no-referrer")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("x-frame-options", "DENY")
        |> put_resp_header(
          "content-security-policy",
          "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' data:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
        )

      cond do
        conn.request_path != path ->
          fail(conn, 400, "Invalid request.")

        conn.method not in methods(route) ->
          conn
          |> put_resp_header("allow", Enum.join(methods(route), ", "))
          |> fail(405, "Method not allowed.")

        true ->
          limited(conn, path)
      end
    else
      conn
    end
  end

  defp methods(path) when path in ["/account/security", "/account/passkeys", "/account/reset"],
    do: ["GET"]

  defp methods(path)
       when path in ["/account/signup", "/account/login", "/account/sessions", "/oauth/authorize"],
       do:
         if(path in ["/account/signup", "/account/login", "/oauth/authorize"],
           do: ["GET", "POST"],
           else: ["GET"]
         )

  defp methods(_), do: ["POST"]
  defp reset_path?("/account/reset"), do: true
  defp reset_path?("/account/reset/" <> token), do: byte_size(token) in 1..256
  defp reset_path?(_), do: false

  defp limited(conn, path) do
    login? =
      conn.method == "POST" and
        (path in @passkey_paths or
           path in [
             "/account/login",
             "/account/signup",
             "/account/security/begin",
             "/account/security/confirm",
             "/account/security/recovery",
             "/account/security/disable"
           ])

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
    limit = if path == "/oauth/authorize", do: 8192, else: 1024

    if byte_size(conn.query_string) <= limit do
      if path == "/oauth/authorize" and conn.query_string != "" do
        case Atoll.OAuth.Form.decode(conn.query_string) do
          {:ok, params} -> dispatch(%{conn | query_params: params, params: params}, path)
          _ -> fail(conn, 400, "Invalid request.")
        end
      else
        dispatch(fetch_query_params(conn), path)
      end
    else
      fail(conn, 400, "Invalid request.")
    end
  end

  defp parse(conn, path) do
    limit =
      if path in ["/account/passkeys/register/finish", "/account/passkeys/login/finish"],
        do: 49_152,
        else: 8192

    with true <- conn.query_string == "",
         true <- get_req_header(conn, "content-encoding") in [[], ["identity"]],
         [type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "x-www-form-urlencoded", _} <- Plug.Conn.Utils.media_type(type),
         {:ok, body, conn} <-
           read_body(conn, length: limit, read_length: limit + 1, read_timeout: 5000),
         {:ok, params} <-
           Atoll.OAuth.Form.decode(body, if(path == "/oauth/authorize", do: 131, else: 13)) do
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
