defmodule AtollWeb.SignupController do
  use AtollWeb, :controller
  alias AtollWeb.AccountController, as: UI
  alias Atoll.OAuth.BrowserConsent
  alias Atoll.Accounts.Signup

  def dispatch(conn) do
    context = get_session(conn, :oauth_pending)

    with true <- conn.query_string == "",
         {:ok, request} <- BrowserConsent.load(context),
         true <- BrowserConsent.creation_required?(context, request) do
      if Application.get_env(:atoll, :signup_enabled, false) do
        if conn.method == "GET",
          do: form(conn, context, request),
          else: create(conn, context, request)
      else
        UI.message(conn, 403, "Account creation is disabled on this server.")
      end
    else
      _ ->
        UI.message(
          conn,
          400,
          "This account-creation request is invalid or expired. Restart signup in the application."
        )
    end
  end

  defp create(conn, context, request) do
    p = conn.body_params

    with true <- Map.keys(p) -- ~w(_csrf_token view handle email password inviteCode) == [],
         true <- p["view"] == context["view"],
         true <- request.parameters["login_hint"] in [nil, p["handle"]],
         {:ok, account} <- Signup.create(input(p), transport()) do
      # Keep the resulting account usable even if registration outlives the PAR.
      # A fresh application request is then required; no expired grant is issued.
      pending = Map.put(context, "created_did", account.did)
      Plug.CSRFProtection.delete_csrf_token()

      conn =
        conn
        |> clear_session()
        |> configure_session(renew: true)
        |> put_session(:account_access, account.accessJwt)
        |> put_session(:account_refresh, account.refreshJwt)
        |> put_session(:account_expires_at, System.system_time(:second) + 3600)

      case BrowserConsent.load(pending) do
        {:ok, _} ->
          conn
          |> put_session(:oauth_pending, pending)
          |> put_resp_header("location", "/oauth/authorize")
          |> send_resp(303, "")

        _ ->
          UI.page(
            conn,
            200,
            "Account created",
            "<p>Your account was created, but the application's request expired. Restart sign-in in the application with your new account.</p><a href=\"/account/sessions\">Manage your account</a>"
          )
      end
    else
      {:error, reason} when reason in [:plc_unavailable, :plc_conflict] ->
        form(
          conn,
          context,
          request,
          "Registration could not be confirmed. Retry with the same handle, email, password and invitation. If your account has already been activated, restart sign-in in the application.",
          503
        )

      {:error, :session_configuration_missing} ->
        UI.message(conn, 503, "Account creation is not configured.")

      _ ->
        form(
          conn,
          context,
          request,
          "Account creation failed. Check your handle, email, password and invitation. The handle must be available and match any account requested by the application.",
          400
        )
    end
  end

  defp input(params) do
    params
    |> Map.take(~w(handle email password inviteCode))
    |> Enum.reject(fn {key, value} -> key in ["email", "inviteCode"] and value == "" end)
    |> Map.new()
  end

  defp form(conn, context, request, error \\ "", status \\ 200) do
    domains =
      Application.get_env(:atoll, :pds, [])
      |> Keyword.get(:available_user_domains, [])
      |> Enum.join(", ")

    hint = request.parameters["login_hint"]
    handle = if is_binary(hint) and Atoll.Syntax.handle?(hint), do: hint, else: ""

    invite_required =
      if Application.get_env(:atoll, :invite_code_required, false), do: " required", else: ""

    UI.page(
      conn,
      status,
      "Create an account",
      "<p>Create an account to connect to <strong>" <>
        e(request.client_id) <>
        "</strong>. You will review permissions before connecting.</p><p role=\"status\">" <>
        e(error) <>
        "</p><p>Handle domains: " <>
        e(domains) <>
        "</p><form method=\"post\" action=\"/account/signup\"><input type=\"hidden\" name=\"_csrf_token\" value=\"" <>
        e(Plug.CSRFProtection.get_csrf_token()) <>
        "\"><input type=\"hidden\" name=\"view\" value=\"" <>
        e(context["view"]) <>
        "\"><label>Full handle<input name=\"handle\" autocomplete=\"username\" required maxlength=\"253\" value=\"" <>
        e(handle) <>
        "\"></label><label>Email (optional)<input name=\"email\" type=\"email\" autocomplete=\"email\" maxlength=\"320\"></label>" <>
        "<label>Password<input name=\"password\" type=\"password\" autocomplete=\"new-password\" required minlength=\"8\" maxlength=\"1024\"></label>" <>
        "<label>Invitation code<input name=\"inviteCode\" maxlength=\"256\"" <>
        invite_required <>
        "></label><p>Keep your password. Creating an account switches this browser to the new account; applications connected to an existing account stay connected.</p><button>Create account</button></form>"
    )
  end

  defp transport,
    do:
      Keyword.merge(
        Application.get_env(:atoll, :identity_resolution_options, []),
        Application.get_env(:atoll, :plc_submission_options, [])
      )

  defp e(value), do: Plug.HTML.html_escape(value)
end
