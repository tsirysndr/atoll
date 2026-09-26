defmodule AtollWeb.AuthenticatorController do
  use AtollWeb, :controller
  alias Atoll.Accounts.Authenticator
  alias AtollWeb.AccountController, as: UI

  def dispatch(%{method: "GET"} = conn, "/account/security") do
    if map_size(conn.query_params) == 0,
      do: show(conn),
      else: UI.message(conn, 400, "Invalid security page.")
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
        UI.page(
          conn,
          200,
          "Set up your authenticator",
          "<p>Add a time-based account in Google Authenticator or another authenticator app. " <>
            "Enter this setup key (six digits, SHA-1, 30 seconds). Keep it private.</p>" <>
            "<p class=\"secret-panel tracking-wider\"><code>" <>
            e(secret) <>
            "</code></p>" <>
            "<p>Setup expires in ten minutes. Enter a code from the app to enable two-factor authentication.</p>" <>
            confirm_form() <> back()
        )

      {:ok, %{recovery_codes: codes}} ->
        UI.page(
          conn,
          200,
          "Save your recovery codes",
          "<p>Two-factor authentication is enabled. Store these codes somewhere safe, separate from your password. " <>
            "Each code works once in place of an authenticator code. Your password is still required.</p>" <>
            "<p class=\"font-semibold\">These codes are shown only now. Any previous recovery codes no longer work.</p>" <>
            "<ul class=\"secret-panel\">" <>
            Enum.map_join(codes, "", &"<li>#{e(&1)}</li>") <> "</ul>" <> back()
        )

      {:ok, :disabled} ->
        show(conn, "Two-factor authentication has been disabled.")

      {:error, reason} when reason in [:invalid_token, :expired_token, :forbidden] ->
        sign_in(conn)

      {:error, reason}
      when reason in [:totp_store_unavailable, :key_vault_unconfigured, :key_decryption_failed] ->
        UI.message(conn, 503, "Account security is temporarily unavailable. Try again later.")

      {:error, :totp_rate_limited} ->
        conn
        |> put_resp_header("retry-after", "300")
        |> show("Too many attempts. Try again in five minutes.", 429)

      {:error, :invalid_credentials} ->
        show(conn, "Your account password was not accepted.", 401)

      {:error, :totp_enrollment_expired} ->
        show(conn, "Setup expired or your password changed. Start setup again.", 400)

      {:error, :totp_already_enabled} ->
        show(conn, "Two-factor authentication is already enabled.", 400)

      {:error, :totp_not_enrolled} ->
        show(conn, "Start authenticator setup first.", 400)

      _ ->
        show(conn, "The request failed. Check your code and try again.", 400)
    end
  end

  defp show(conn, notice \\ "", status \\ 200) do
    case Authenticator.status(get_session(conn, :account_access)) do
      {:ok, factor} ->
        content =
          if factor.state == :enabled do
            "<p>Authenticator protection is enabled. Recovery codes remaining: <strong>" <>
              Integer.to_string(factor.recovery_remaining) <>
              "</strong>.</p>" <>
              "<p>Security changes require your account password and a fresh authenticator or recovery code.</p>" <>
              "<h2>Replace recovery codes</h2><p>This invalidates every previous recovery code.</p>" <>
              form("recovery", password_input() <> code_input(), "Replace recovery codes") <>
              "<h2>Disable two-factor authentication</h2><p>Future password sign-ins will no longer require an authenticator code. " <>
              "To replace a lost authenticator, disable it with a recovery code, then set up a new one.</p>" <>
              form(
                "disable",
                password_input() <> code_input(),
                "Disable two-factor authentication"
              )
          else
            pending =
              if factor.state == :pending, do: "<h2>Finish setup</h2>" <> confirm_form(), else: ""

            "<p>Authenticator protection is not enabled. You can optionally require a code when signing in with your password.</p>" <>
              pending <>
              "<h2>Set up an authenticator</h2>" <>
              "<p>Enter your account password to create a setup key. Starting again replaces any unfinished setup.</p>" <>
              form("begin", password_input(), "Start setup")
          end

        UI.page(
          conn,
          status,
          "Account security",
          "<p role=\"status\">" <>
            e(notice) <>
            "</p>" <>
            content <>
            "<p>Existing sessions and app passwords stay active when you change authenticator settings. " <>
            "If a device was lost, review connected applications.</p>" <> back()
        )

      {:error, :totp_store_unavailable} ->
        UI.message(conn, 503, "Account storage is unavailable.")

      _ ->
        sign_in(conn)
    end
  end

  defp confirm_form, do: form("confirm", code_input(), "Enable two-factor authentication")

  defp password_input,
    do:
      "<label>Account password<input type=\"password\" name=\"password\" autocomplete=\"current-password\" required minlength=\"8\" maxlength=\"1024\"></label>"

  defp code_input,
    do:
      "<label>Authenticator or recovery code<input name=\"totpCode\" autocomplete=\"one-time-code\" required pattern=\"([0-9]{6}|[A-Z2-7]{26})\" maxlength=\"26\"></label>"

  defp form(action, inputs, label),
    do:
      "<form method=\"post\" action=\"/account/security/" <>
        action <>
        "\"><input type=\"hidden\" name=\"_csrf_token\" value=\"" <>
        e(Plug.CSRFProtection.get_csrf_token()) <>
        "\">" <> inputs <> "<button>" <> e(label) <> "</button></form>"

  defp back,
    do:
      "<p><a href=\"/account/security\">Account security</a> · <a href=\"/account/sessions\">Connected applications</a></p>"

  defp fields?(params, allowed), do: Map.keys(params) -- allowed == []
  defp e(value), do: Plug.HTML.html_escape(value)

  defp sign_in(conn),
    do:
      conn
      |> clear_session()
      |> configure_session(drop: true)
      |> put_resp_header("location", "/account/login")
      |> send_resp(303, "")
end
