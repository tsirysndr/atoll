defmodule AtollWeb.AccountController do
  use AtollWeb, :controller
  alias Atoll.Accounts.Sessions
  alias Atoll.OAuth.SessionManagement

  def dispatch(conn, "/oauth/authorize"), do: AtollWeb.ConsentController.dispatch(conn)

  def dispatch(%{method: "GET"} = conn, "/account/login") do
    if get_session(conn, :account_access),
      do: go(conn, after_login(conn)),
      else: login_form(conn)
  end

  def dispatch(%{method: "POST"} = conn, "/account/login"), do: login(conn)

  def dispatch(conn, path)
      when path in [
             "/account/security",
             "/account/security/begin",
             "/account/security/confirm",
             "/account/security/recovery",
             "/account/security/disable"
           ],
      do: AtollWeb.AuthenticatorController.dispatch(conn, path)

  def dispatch(conn, "/account/sessions"), do: sessions(conn)
  def dispatch(conn, "/account/sessions/revoke"), do: revoke(conn)
  def dispatch(conn, "/account/logout"), do: logout(conn)

  defp login(conn) do
    p = conn.body_params

    if get_session(conn, :account_access) do
      go(conn, after_login(conn))
    else
      with true <-
             Map.keys(p) -- ~w(_csrf_token identifier password authFactorToken totpCode) == [],
           identifier when is_binary(identifier) and byte_size(identifier) in 1..2048 <-
             p["identifier"],
           password when is_binary(password) and byte_size(password) in 8..1024 <- p["password"],
           true <- p["authFactorToken"] in [nil, ""] or byte_size(p["authFactorToken"]) == 32,
           {:ok, pair} <- authenticate(identifier, password, p["authFactorToken"], p["totpCode"]),
           :ok <- full_account(pair) do
        pending = get_session(conn, :oauth_pending)
        Plug.CSRFProtection.delete_csrf_token()

        conn
        |> clear_session()
        |> configure_session(renew: true)
        |> put_session(:account_access, pair.access_jwt)
        |> put_session(:account_refresh, pair.refresh_jwt)
        |> put_session(:account_expires_at, System.system_time(:second) + 3600)
        |> put_session(:oauth_pending, pending)
        |> go(if(pending, do: "/oauth/authorize", else: "/account/sessions"))
      else
        {:error, :totp_required} ->
          login_form(
            conn,
            "Enter the current six-digit code from your authenticator app, or an unused recovery code.",
            401
          )

        {:error, :totp_rate_limited} ->
          login_form(conn, "Too many authenticator attempts. Try again in five minutes.", 429)

        {:error, :auth_factor_required} ->
          login_form(
            conn,
            "Check your email for a sign-in code, then enter it with your password.",
            401
          )

        {:error, :session_configuration_missing} ->
          message(conn, 503, "Account login is not configured.")

        _ ->
          login_form(
            conn,
            "Sign-in failed. Use your account password and an email address or DID.",
            401
          )
      end
    end
  end

  defp after_login(conn),
    do: if(get_session(conn, :oauth_pending), do: "/oauth/authorize", else: "/account/sessions")

  defp authenticate(identifier, password, factor, totp) do
    opts = if factor in [nil, ""], do: [], else: [auth_factor_token: factor]

    opts = Keyword.put(opts, :totp_code, totp)

    if Atoll.Syntax.did?(identifier),
      do: Sessions.create(identifier, password, opts),
      else: Sessions.create_email(identifier, password, opts)
  end

  defp full_account(pair) do
    case Sessions.authenticate_management(pair.access_jwt) do
      {:ok, _} ->
        :ok

      error ->
        Sessions.revoke(pair.refresh_jwt)
        error
    end
  end

  defp sessions(conn) do
    params = conn.query_params

    if Map.keys(params) -- ["cursor"] != [] do
      message(conn, 400, "Invalid page.")
    else
      case SessionManagement.list(get_session(conn, :account_access), 50, params["cursor"]) do
        {:ok, page} ->
          rows =
            Enum.map_join(page.sessions, "", fn s ->
              "<li><p><strong>" <>
                e(s.clientId) <>
                "</strong></p><p>Permissions: " <>
                e(s.scope) <>
                "</p><p>Expires: " <>
                e(DateTime.from_unix!(s.expiresAt) |> DateTime.to_iso8601()) <>
                "</p><form method=\"post\" action=\"/account/sessions/revoke\">" <>
                csrf() <>
                "<input type=\"hidden\" name=\"id\" value=\"" <>
                e(s.id) <> "\"><button>Revoke access</button></form></li>"
            end)

          next =
            if page[:cursor],
              do:
                "<p><a href=\"/account/sessions?cursor=" <>
                  e(page.cursor) <> "\">Next page</a></p>",
              else: ""

          content =
            if rows == "", do: "<p>No active OAuth sessions.</p>", else: "<ul>" <> rows <> "</ul>"

          page(
            conn,
            200,
            "Connected applications",
            "<p><a href=\"/account/security\">Account security</a></p><p>Revoking access disconnects this application. Other applications remain connected.</p>" <>
              content <>
              next <>
              "<form method=\"post\" action=\"/account/logout\">" <>
              csrf() <>
              "<button>Sign out and disconnect applications authorized in this browser</button></form>"
          )

        {:error, :invalid_request} ->
          message(conn, 400, "Invalid page.")

        {:error, :oauth_session_store_unavailable} ->
          message(conn, 503, "Account storage is unavailable. Try again later.")

        _ ->
          conn |> clear_session() |> configure_session(drop: true) |> go("/account/login")
      end
    end
  end

  defp revoke(conn) do
    if Map.keys(conn.body_params) -- ~w(_csrf_token id) == [] do
      case SessionManagement.revoke(get_session(conn, :account_access), conn.body_params["id"]) do
        {:ok, :ok} ->
          go(conn, "/account/sessions")

        {:error, :invalid_request} ->
          message(conn, 400, "Invalid session.")

        {:error, :oauth_session_store_unavailable} ->
          message(conn, 503, "Account storage is unavailable. Try again later.")

        _ ->
          conn |> clear_session() |> configure_session(drop: true) |> go("/account/login")
      end
    else
      message(conn, 400, "Invalid form.")
    end
  end

  defp logout(conn) do
    result =
      case get_session(conn, :account_refresh) do
        nil -> {:ok, :ok}
        token -> Sessions.revoke(token)
      end

    case result do
      {:ok, :ok} -> drop_login(conn)
      {:error, reason} when reason in [:invalid_token, :expired_token] -> drop_login(conn)
      _ -> message(conn, 503, "Sign-out could not complete. Try again later.")
    end
  end

  defp drop_login(conn) do
    Plug.CSRFProtection.delete_csrf_token()
    conn |> clear_session() |> configure_session(drop: true) |> go("/account/login")
  end

  defp login_form(conn, error \\ "", status \\ 200) do
    page(
      conn,
      status,
      "Sign in",
      "<p class=\"text-center text-sm text-subtle\">Enter your account credentials to continue.</p><p role=\"status\">" <>
        e(error) <>
        "</p><form method=\"post\" action=\"/account/login\">" <>
        csrf() <>
        "<label>Email or DID<input name=\"identifier\" autocomplete=\"username\" autofocus required maxlength=\"2048\"></label>" <>
        "<label>Account password<input type=\"password\" name=\"password\" autocomplete=\"current-password\" required maxlength=\"1024\"></label>" <>
        "<details class=\"my-5\"" <>
        if(status == 200, do: "", else: " open") <>
        "><summary>Two-factor authentication</summary><label>Email sign-in code (if requested)<input name=\"authFactorToken\" autocomplete=\"one-time-code\" maxlength=\"32\"></label>" <>
        "<label>Authenticator or recovery code (if enabled)<input name=\"totpCode\" pattern=\"([0-9]{6}|[A-Z2-7]{26})\" autocomplete=\"one-time-code\" maxlength=\"26\"></label>" <>
        "</details><button>Sign in</button></form>"
    )
  end

  def message(conn, status, text),
    do:
      page(
        conn,
        status,
        "Atoll account",
        "<p>" <> e(text) <> "</p><a href=\"/account/login\">Sign in</a>"
      )

  defp csrf,
    do:
      "<input type=\"hidden\" name=\"_csrf_token\" value=\"" <>
        e(Plug.CSRFProtection.get_csrf_token()) <> "\">"

  defp e(value), do: Plug.HTML.html_escape(value)
  defp go(conn, path), do: conn |> put_resp_header("location", path) |> send_resp(303, "")

  def page(conn, status, title, content) do
    width =
      if conn.request_path in ["/account/login", "/oauth/authorize"],
        do: "max-w-sm",
        else: "max-w-2xl"

    html =
      "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>" <>
        e(title) <>
        "</title><link rel=\"stylesheet\" href=\"" <>
        e(AtollWeb.Endpoint.static_path("/assets/account.css")) <>
        "\"></head><body class=\"account-background\"><div class=\"flex min-h-svh flex-col items-center justify-center p-6 md:p-10\"><main class=\"w-full " <>
        width <>
        " overflow-hidden rounded-xl border border-edge bg-surface pt-4\"><header class=\"mb-4 px-4 pt-2 text-center font-medium\">Atoll PDS</header><div class=\"px-4\"><h1>" <>
        e(title) <>
        "</h1>" <>
        content <>
        "</div><footer class=\"mt-4 border-t border-edge bg-muted/50 p-4 text-center text-sm\"><select aria-label=\"Language\" class=\"h-7 rounded-lg border border-edge bg-transparent px-2\"><option value=\"en\">🇺🇸 English</option></select></footer></main></div></body></html>"

    conn |> put_resp_content_type("text/html") |> send_resp(status, html)
  end
end
