defmodule AtollWeb.ConsentController do
  use AtollWeb, :controller
  alias AtollWeb.AccountController, as: UI
  alias Atoll.OAuth.{BrowserConsent, AuthorizationCodes}
  alias Atoll.Accounts.Sessions

  @labels [
    {"transition:generic", "generic",
     "Write records, upload media, use application services and preferences"},
    {"transition:chat.bsky", "chat",
     "Access Bluesky direct messages (also requires general application access)"},
    {"transition:email", "email", "Read your email address and confirmation status"}
  ]

  def dispatch(%{method: "GET"} = conn) do
    case context(conn) do
      {:ok, context} ->
        conn = put_session(conn, :oauth_pending, context)

        case Sessions.authenticate_management(get_session(conn, :account_access)) do
          {:ok, %{did: did, status: :active}} ->
            show(conn, context, did)

          {:ok, _} ->
            UI.message(conn, 400, "This account cannot authorize applications while inactive.")

          _ ->
            conn
            |> delete_session(:account_access)
            |> delete_session(:account_refresh)
            |> delete_session(:account_expires_at)
            |> go("/account/login")
        end

      _ ->
        UI.message(
          conn,
          400,
          "This authorization request is invalid or expired. Restart sign-in in the application."
        )
    end
  end

  def dispatch(%{method: "POST"} = conn) do
    p = conn.body_params
    context = get_session(conn, :oauth_pending)

    with true <- Map.keys(p) -- ~w(_csrf_token view decision generic chat email) == [],
         %{"view" => view, "did" => did, "uri" => uri} <- context,
         true <- p["view"] == view,
         {:ok, request} <- BrowserConsent.load(context),
         :ok <- BrowserConsent.account_matches(request, did),
         {:ok, decision} <- decision(p, request),
         {:ok, result} <-
           AuthorizationCodes.decide(
             get_session(conn, :account_access),
             request.client_id,
             uri,
             decision,
             transport() ++ [expected_did: did]
           ) do
      conn |> delete_session(:oauth_pending) |> go(BrowserConsent.callback(result))
    else
      _ ->
        UI.message(
          conn,
          400,
          "Authorization could not complete. Check the selected account and permissions, or restart sign-in in the application."
        )
    end
  end

  defp context(conn) do
    case conn.query_params do
      params when map_size(params) == 0 ->
        context = get_session(conn, :oauth_pending)
        with {:ok, _} <- BrowserConsent.load(context), do: {:ok, context}

      %{"client_id" => client, "request_uri" => uri} = params when map_size(params) == 2 ->
        BrowserConsent.start(client, uri)

      _ ->
        {:error, :invalid_request}
    end
  end

  defp show(conn, context, did) do
    with {:ok, request} <- BrowserConsent.load(context),
         :ok <- BrowserConsent.account_matches(request, did) do
      scopes = String.split(request.parameters["scope"], " ")

      choices =
        Enum.map_join(@labels, "", fn {scope, field, label} ->
          if scope in scopes,
            do:
              "<label><input type=\"checkbox\" name=\"" <>
                field <>
                "\" value=\"yes\" checked>" <> e(label) <> "</label>",
            else: ""
        end)

      # A form-action restriction on the initiating page can block the OAuth callback redirect.
      conn =
        put_resp_header(
          conn,
          "content-security-policy",
          "default-src 'none'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'"
        )

      conn = put_session(conn, :oauth_pending, Map.put(context, "did", did))

      UI.page(
        conn,
        200,
        "Connect an application",
        "<p>Application: <strong>" <>
          e(request.client_id) <>
          "</strong></p><p>Account: <strong>" <>
          e(did) <>
          "</strong></p><p>This application will learn your account DID. Choose any additional permissions below.</p>" <>
          "<form method=\"post\" action=\"/oauth/authorize\"><input type=\"hidden\" name=\"_csrf_token\" value=\"" <>
          e(Plug.CSRFProtection.get_csrf_token()) <>
          "\"><input type=\"hidden\" name=\"view\" value=\"" <>
          e(context["view"]) <>
          "\">" <>
          choices <>
          "<button name=\"decision\" value=\"approve\">Allow selected permissions</button> " <>
          "<button name=\"decision\" value=\"deny\">Deny</button></form>" <>
          "<p>Signing out of this browser revokes access granted through this sign-in. You can revoke applications individually on your account page.</p>" <>
          "<a href=\"/account/sessions\">Manage account or sign out to use another account</a>"
      )
    else
      _ ->
        UI.message(
          conn,
          400,
          "This request is for a different account or has expired. Sign out to choose the requested account, or restart sign-in in the application."
        )
    end
  end

  defp decision(%{"decision" => "deny"}, _), do: {:ok, :deny}

  defp decision(%{"decision" => "approve"} = p, request) do
    requested = String.split(request.parameters["scope"], " ")
    selected = Enum.filter(@labels, fn {_, field, _} -> p[field] == "yes" end)

    if Enum.all?(@labels, fn {scope, field, _} ->
         is_nil(p[field]) or (p[field] == "yes" and scope in requested)
       end),
       do: {:ok, {:approve, Enum.join(["atproto" | Enum.map(selected, &elem(&1, 0))], " ")}},
       else: {:error, :invalid_scope}
  end

  defp decision(_, _), do: {:error, :invalid_consent}

  defp transport,
    do:
      Application.get_env(:atoll, :oauth_transport_options, [])
      |> Keyword.take([:request, :lookup])

  defp e(value), do: Plug.HTML.html_escape(value)
  defp go(conn, url), do: conn |> put_resp_header("location", url) |> send_resp(303, "")
end
