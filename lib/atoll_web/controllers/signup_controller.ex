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

    with true <- Map.keys(p) -- ~w(_csrf_token view handle email password inviteCode action) == [],
         true <- p["view"] == context["view"],
         true <- request.parameters["login_hint"] in [nil, p["handle"]],
         {:ok, result} <- signup_action(p) do
      case result do
        {:account, account} -> created(conn, context, account)
        {:reservation, reservation} -> form(conn, context, request, "", 200, reservation)
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

      {:error, :signup_reservation_unavailable} ->
        form(
          conn,
          context,
          request,
          "New custom-domain reservations are temporarily unavailable. Retry later or contact the server operator.",
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

  defp created(conn, context, account) do
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
  end

  defp signup_action(%{"action" => "reserve_custom"} = params) do
    with {:ok, reservation} <- Signup.reserve_custom_self_service(input(params)),
         do: {:ok, {:reservation, reservation}}
  end

  defp signup_action(params) do
    if params["action"] in [nil, "create"] do
      with {:ok, account} <- Signup.create(input(params), transport()),
           do: {:ok, {:account, account}}
    else
      {:error, :invalid_request}
    end
  end

  defp input(params) do
    params
    |> Map.take(~w(handle email password inviteCode))
    |> Enum.reject(fn {key, value} -> key in ["email", "inviteCode"] and value == "" end)
    |> Map.new()
  end

  defp form(conn, context, request, error \\ "", status \\ 200, reservation \\ nil) do
    domains =
      Application.get_env(:atoll, :pds, [])
      |> Keyword.get(:available_user_domains, [])
      |> Enum.join(", ")

    hint = request.parameters["login_hint"]
    handle = if is_binary(hint) and Atoll.Syntax.handle?(hint), do: hint, else: ""

    handle = if reservation, do: reservation.handle, else: handle

    setup =
      if reservation do
        "<section aria-label=\"Custom handle setup\"><h2>Connect your domain</h2><p>Your reserved DID is <code>" <>
          e(reservation.did) <>
          "</code>.</p><p>Add a DNS TXT record at <code>" <>
          e(reservation.dns_name) <>
          "</code> with value <code>" <>
          e(reservation.dns_value) <>
          "</code>, or serve your DID as plain text at <code>" <>
          e(reservation.https_url) <>
          "</code>.</p><p>Then create your account below using the same handle, email, password and invitation. Keep those details; this page does not store your password. If the application request expires while DNS updates, restart signup in the application and reuse the same details.</p></section>"
      else
        ""
      end

    reserve_button =
      if Signup.self_service_custom_enabled?() do
        "<p>Using your own domain? Reserve your DID first, then configure its DNS or HTTPS claim.</p><button name=\"action\" value=\"reserve_custom\">Reserve a custom-domain DID</button>"
      else
        ""
      end

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
        "</p>" <>
        setup <>
        "<form method=\"post\" action=\"/account/signup\"><input type=\"hidden\" name=\"_csrf_token\" value=\"" <>
        e(Plug.CSRFProtection.get_csrf_token()) <>
        "\"><input type=\"hidden\" name=\"view\" value=\"" <>
        e(context["view"]) <>
        "\"><label>Full handle<input name=\"handle\" autocomplete=\"username\" required maxlength=\"253\" value=\"" <>
        e(handle) <>
        "\"></label><label>Email (optional)<input name=\"email\" type=\"email\" autocomplete=\"email\" maxlength=\"320\"></label>" <>
        "<label>Password<input name=\"password\" type=\"password\" autocomplete=\"new-password\" required minlength=\"8\" maxlength=\"1024\"></label>" <>
        "<label>Invitation code<input name=\"inviteCode\" maxlength=\"256\"" <>
        invite_required <>
        "></label><p>Keep your password. Creating an account switches this browser to the new account; applications connected to an existing account stay connected.</p><button name=\"action\" value=\"create\">Create account</button>" <>
        reserve_button <> "</form>"
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
