defmodule AtollWeb.AuthenticatorController do
  use AtollWeb, :controller
  alias Atoll.Accounts.Authenticator
  alias AtollWeb.AccountController, as: UI

  def dispatch(%{method: "GET"} = conn, "/account/security") do
    if map_size(conn.query_params) == 0,
      do: show(conn),
      else: UI.message(conn, 400, "invalid_page")
  end

  def dispatch(conn, path) do
    p = conn.body_params
    token = get_session(conn, :account_access)

    result =
      case path do
        "/account/security/begin" ->
          if fields?(p, ~w(_csrf_token password)),
            do: Authenticator.begin(token, p["password"]),
            else: {:error, :invalid_request}

        "/account/security/confirm" ->
          if fields?(p, ~w(_csrf_token totpCode)),
            do: Authenticator.confirm(token, p["totpCode"]),
            else: {:error, :invalid_request}

        "/account/security/recovery" ->
          if fields?(p, ~w(_csrf_token password totpCode)),
            do: Authenticator.regenerate(token, p["password"], p["totpCode"]),
            else: {:error, :invalid_request}

        "/account/security/disable" ->
          if fields?(p, ~w(_csrf_token password totpCode)),
            do: Authenticator.disable(token, p["password"], p["totpCode"]),
            else: {:error, :invalid_request}
      end

    case result do
      {:ok, %{secret: secret}} ->
        screen(conn, 200, %{state: :pending, secret: secret})

      {:ok, %{recovery_codes: codes}} ->
        screen(conn, 200, %{state: :enabled, recovery_codes: codes})

      {:ok, :disabled} ->
        show(conn, "", 200, "totp_disabled")

      {:error, reason} when reason in [:invalid_token, :expired_token, :forbidden] ->
        sign_in(conn)

      {:error, reason}
      when reason in [:totp_store_unavailable, :key_vault_unconfigured, :key_decryption_failed] ->
        UI.message(conn, 503, "storage_unavailable")

      {:error, :totp_rate_limited} ->
        conn
        |> put_resp_header("retry-after", "300")
        |> show("totp_rate_limited", 429)

      {:error, :invalid_credentials} ->
        show(conn, "invalid_credentials", 401)

      {:error, :totp_enrollment_expired} ->
        show(conn, "totp_enrollment_expired", 400)

      {:error, :totp_already_enabled} ->
        show(conn, "totp_already_enabled", 400)

      {:error, :totp_not_enrolled} ->
        show(conn, "totp_not_enrolled", 400)

      _ ->
        show(conn, "totp_failed", 400)
    end
  end

  defp show(conn, error \\ "", status \\ 200, notice \\ "") do
    case Authenticator.status(get_session(conn, :account_access)) do
      {:ok, factor} ->
        screen(conn, status, %{
          state: factor.state,
          error: error,
          notice: notice,
          recovery_remaining: Map.get(factor, :recovery_remaining, 0)
        })

      {:error, :totp_store_unavailable} ->
        UI.message(conn, 503, "storage_unavailable")

      _ ->
        sign_in(conn)
    end
  end

  defp screen(conn, status, data) do
    AtollWeb.Shell.render(conn, status, %{
      screen: "security",
      title: "Account security",
      error: Map.get(data, :error, ""),
      notice: Map.get(data, :notice, ""),
      state: to_string(data.state),
      recoveryRemaining: Map.get(data, :recovery_remaining, 0),
      secret: Map.get(data, :secret),
      recoveryCodes: Map.get(data, :recovery_codes)
    })
  end

  defp fields?(params, allowed), do: Map.keys(params) -- allowed == []

  defp sign_in(conn),
    do:
      conn
      |> clear_session()
      |> configure_session(drop: true)
      |> put_resp_header("location", "/account/login")
      |> send_resp(303, "")
end
