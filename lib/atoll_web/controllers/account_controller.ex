defmodule AtollWeb.AccountController do
  use AtollWeb, :controller
  alias Atoll.Accounts.{LoginIdentifier, Sessions}
  alias Atoll.OAuth.{BrowserConsent, SessionManagement}
  alias AtollWeb.Shell

  def dispatch(conn, "/account/passkeys" <> _ = path),
    do: AtollWeb.PasskeyController.dispatch(conn, path)

  def dispatch(conn, "/account/signup"), do: AtollWeb.SignupController.dispatch(conn)

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
        signed_in(conn, pair)
      else
        {:error, :totp_required} ->
          login_form(conn, "totp_required", 401)

        {:error, :totp_rate_limited} ->
          login_form(conn, "totp_rate_limited", 429)

        {:error, :auth_factor_required} ->
          login_form(conn, "auth_factor_required", 401)

        {:error, :session_configuration_missing} ->
          message(conn, 503, "login_not_configured")

        _ ->
          login_form(conn, "invalid_credentials", 401)
      end
    end
  end

  @doc false
  def signed_in(conn, pair) do
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
  end

  defp after_login(conn),
    do: if(get_session(conn, :oauth_pending), do: "/oauth/authorize", else: "/account/sessions")

  defp authenticate(identifier, password, factor, totp) do
    opts = if factor in [nil, ""], do: [], else: [auth_factor_token: factor]
    opts = Keyword.put(opts, :totp_code, totp)

    with {:ok, pair, _handle} <- LoginIdentifier.create_session(identifier, password, opts),
         do: {:ok, pair}
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
      message(conn, 400, "invalid_page")
    else
      case SessionManagement.list(get_session(conn, :account_access), 50, params["cursor"]) do
        {:ok, page} ->
          Shell.render(conn, 200, %{
            screen: "sessions",
            title: "Connected applications",
            sessions:
              Enum.map(page.sessions, fn session ->
                %{
                  id: session.id,
                  clientId: session.clientId,
                  scope: session.scope,
                  expiresAt: session.expiresAt
                }
              end),
            cursor: page[:cursor]
          })

        {:error, :invalid_request} ->
          message(conn, 400, "invalid_page")

        {:error, :oauth_session_store_unavailable} ->
          message(conn, 503, "storage_unavailable")

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
          message(conn, 400, "invalid_session")

        {:error, :oauth_session_store_unavailable} ->
          message(conn, 503, "storage_unavailable")

        _ ->
          conn |> clear_session() |> configure_session(drop: true) |> go("/account/login")
      end
    else
      message(conn, 400, "invalid_form")
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
      _ -> message(conn, 503, "signout_failed")
    end
  end

  defp drop_login(conn) do
    Plug.CSRFProtection.delete_csrf_token()
    conn |> clear_session() |> configure_session(drop: true) |> go("/account/login")
  end

  defp login_form(conn, error \\ "", status \\ 200) do
    Shell.render(conn, status, %{
      screen: "login",
      title: "Sign in",
      error: error,
      identifier: login_hint(conn),
      passkeysEnabled: Atoll.Accounts.Passkeys.enabled?(),
      showTwoFactor: error in ["totp_required", "auth_factor_required", "totp_rate_limited"],
      signupEnabled: Application.get_env(:atoll, :signup_enabled, false),
      client: pending_client(conn)
    })
  end

  @doc false
  def pending_client(conn) do
    with context when is_map(context) <- get_session(conn, :oauth_pending),
         {:ok, request} <- BrowserConsent.load(context) do
      client(request.client_id)
    else
      _ -> nil
    end
  end

  @doc false
  def client(client_id) do
    name =
      case URI.parse(client_id) do
        %URI{host: host} when is_binary(host) and host != "" -> host
        _ -> client_id
      end

    %{id: client_id, name: name}
  end

  defp login_hint(conn) do
    with context when is_map(context) <- get_session(conn, :oauth_pending),
         {:ok, request} <- BrowserConsent.load(context),
         hint when is_binary(hint) <- request.parameters["login_hint"],
         true <- Atoll.Syntax.handle?(hint) or Atoll.Syntax.did?(hint) do
      hint
    else
      _ -> ""
    end
  end

  def message(conn, status, code), do: Shell.message(conn, status, code)

  defp go(conn, path), do: conn |> put_resp_header("location", path) |> send_resp(303, "")
end
