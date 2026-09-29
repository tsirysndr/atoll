defmodule AtollWeb.SignupController do
  use AtollWeb, :controller
  alias AtollWeb.AccountController, as: UI
  alias AtollWeb.Shell
  alias Atoll.OAuth.BrowserConsent
  alias Atoll.Accounts.Signup

  def dispatch(conn) do
    context = get_session(conn, :oauth_pending)

    cond do
      conn.query_string != "" ->
        UI.message(conn, 400, "signup_request_invalid")

      # Direct signup, outside any application request.
      is_nil(context) ->
        guarded(conn, nil, nil)

      true ->
        case BrowserConsent.load(context) do
          {:ok, request} ->
            if BrowserConsent.creation_required?(context, request),
              do: guarded(conn, context, request),
              else: UI.message(conn, 400, "signup_request_invalid")

          _ ->
            UI.message(conn, 400, "signup_request_invalid")
        end
    end
  end

  defp guarded(conn, context, request) do
    if Application.get_env(:atoll, :signup_enabled, false) do
      if conn.method == "GET",
        do: form(conn, context, request),
        else: create(conn, context, request)
    else
      UI.message(conn, 403, "signup_disabled")
    end
  end

  defp create(conn, context, request) do
    p = conn.body_params

    # confirmPassword is checked in the browser and posted with the form; it is
    # accepted here and dropped below rather than failing the whole request.
    with true <-
           Map.keys(p) --
             ~w(_csrf_token view handle email password confirmPassword inviteCode action) == [],
         true <- is_nil(context) or p["view"] == context["view"],
         true <- is_nil(request) or request.parameters["login_hint"] in [nil, p["handle"]],
         {:ok, result} <- signup_action(p) do
      case result do
        {:account, account} -> created(conn, context, account)
        {:reservation, reservation} -> form(conn, context, request, "", 200, reservation)
      end
    else
      {:error, reason} when reason in [:plc_unavailable, :plc_conflict] ->
        form(conn, context, request, "signup_unconfirmed", 503)

      {:error, :signup_reservation_unavailable} ->
        form(conn, context, request, "reservation_unavailable", 503)

      {:error, :session_configuration_missing} ->
        UI.message(conn, 503, "signup_not_configured")

      _ ->
        form(conn, context, request, "signup_failed", 400)
    end
  end

  defp created(conn, nil, account) do
    conn
    |> sign_in(account)
    |> put_resp_header("location", "/account/sessions")
    |> send_resp(303, "")
  end

  defp created(conn, context, account) do
    # Keep the resulting account usable even if registration outlives the PAR.
    # A fresh application request is then required; no expired grant is issued.
    pending = Map.put(context, "created_did", account.did)
    conn = sign_in(conn, account)

    case BrowserConsent.load(pending) do
      {:ok, _} ->
        conn
        |> put_session(:oauth_pending, pending)
        |> put_resp_header("location", "/oauth/authorize")
        |> send_resp(303, "")

      _ ->
        Shell.render(conn, 200, %{
          screen: "message",
          title: "Account created",
          notice: "account_created_expired",
          text: "account_created_expired",
          error: "",
          link: %{href: "/account/sessions", label: "Manage your account"}
        })
    end
  end

  defp sign_in(conn, account) do
    Plug.CSRFProtection.delete_csrf_token()

    conn
    |> clear_session()
    |> configure_session(renew: true)
    |> put_session(:account_access, account.accessJwt)
    |> put_session(:account_refresh, account.refreshJwt)
    |> put_session(:account_expires_at, System.system_time(:second) + 3600)
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
    hint = request && request.parameters["login_hint"]
    handle = if is_binary(hint) and Atoll.Syntax.handle?(hint), do: hint, else: ""
    handle = if reservation, do: reservation.handle, else: handle

    Shell.render(conn, status, %{
      screen: "signup",
      title: "Create an account",
      error: error,
      view: context && context["view"],
      handle: handle,
      email: "",
      handleDomains:
        Application.get_env(:atoll, :pds, []) |> Keyword.get(:available_user_domains, []),
      inviteRequired: Atoll.Accounts.Invites.required?(),
      customDomainEnabled: Signup.self_service_custom_enabled?(),
      reservation:
        reservation &&
          %{
            did: reservation.did,
            handle: reservation.handle,
            dnsName: reservation.dns_name,
            dnsValue: reservation.dns_value,
            httpsUrl: reservation.https_url
          },
      client: request && UI.client(request.client_id)
    })
  end

  defp transport,
    do:
      Keyword.merge(
        Application.get_env(:atoll, :identity_resolution_options, []),
        Application.get_env(:atoll, :plc_submission_options, [])
      )
end
