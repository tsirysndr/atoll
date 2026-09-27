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
    with {:ok, context} <- context(conn),
         {:ok, request} <- BrowserConsent.load(context) do
      conn = put_session(conn, :oauth_pending, context)

      if BrowserConsent.creation_required?(context, request) do
        go(conn, "/account/signup")
      else
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
      end
    else
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

    with %{"view" => view, "did" => did, "uri" => uri} <- context,
         true <- p["view"] == view,
         {:ok, request} <- BrowserConsent.load(context),
         true <-
           Map.keys(p) --
             (~w(_csrf_token view decision) ++ Enum.map(permissions(request), &elem(&1, 1))) == [],
         true <- BrowserConsent.creation_matches?(context, request, did),
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
        with {:ok, fresh} <- BrowserConsent.start(client, uri) do
          client_hash = fresh["client"]

          case get_session(conn, :oauth_pending) do
            %{"uri" => ^uri, "client" => ^client_hash} = existing ->
              {:ok, existing}

            _ ->
              {:ok, fresh}
          end
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp show(conn, context, did) do
    with {:ok, request} <- BrowserConsent.load(context),
         true <- BrowserConsent.creation_matches?(context, request, did),
         :ok <- BrowserConsent.account_matches(request, did) do
      choices =
        Enum.map_join(permissions(request), "", fn {scope, field, label} ->
          label = set_title(scope, request, conn) || label

          "<label class=\"permission-option\"><input type=\"checkbox\" name=\"" <>
            field <>
            "\" value=\"yes\" checked><span>" <>
            e(label) <> "</span></label>" <> set_details(scope, request, conn)
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
        "Authorize",
        "<p class=\"auth-subtitle\">Grant access to your account:<strong class=\"auth-identity\">" <>
          e(did) <>
          "</strong></p><section class=\"application-panel\" aria-label=\"Application\"><p><strong>" <>
          e(request.client_id) <>
          "</strong></p><p class=\"auth-note\">wants to access your account</p></section>" <>
          "<p class=\"auth-note\">This application will learn your account DID. Choose any additional permissions below.</p>" <>
          "<form method=\"post\" action=\"/oauth/authorize\"><input type=\"hidden\" name=\"_csrf_token\" value=\"" <>
          e(Plug.CSRFProtection.get_csrf_token()) <>
          "\"><input type=\"hidden\" name=\"view\" value=\"" <>
          e(context["view"]) <>
          "\">" <>
          choices <>
          "<div class=\"auth-actions\"><button name=\"decision\" value=\"approve\">Authorize</button>" <>
          "<button name=\"decision\" value=\"deny\">Deny access</button></div></form>" <>
          "<p class=\"auth-note\">Signing out of this browser revokes access granted through this sign-in. You can revoke applications individually on your account page.</p>" <>
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
    choices = permissions(request)
    selected = Enum.filter(choices, fn {_, field, _} -> p[field] == "yes" end)

    if Enum.all?(choices, fn {_, field, _} ->
         is_nil(p[field]) or p[field] == "yes"
       end),
       do: {:ok, {:approve, Enum.join(["atproto" | Enum.map(selected, &elem(&1, 0))], " ")}},
       else: {:error, :invalid_scope}
  end

  defp decision(_, _), do: {:error, :invalid_consent}

  defp permissions(request) do
    scopes = String.split(request.parameters["scope"], " ")
    legacy = Enum.filter(@labels, fn {scope, _, _} -> scope in scopes end)

    granular =
      scopes
      |> Enum.with_index()
      |> Enum.flat_map(fn {scope, index} ->
        case permission_label(scope, request) do
          label when is_binary(label) ->
            [
              {scope, "permission_" <> Integer.to_string(index), label}
            ]

          _ ->
            []
        end
      end)

    legacy ++ granular
  end

  defp permission_label(scope, request) do
    case Atoll.OAuth.PermissionSnapshots.entry(scope, request.permission_sets) do
      {:ok, entry} -> entry["title"] || scope
      _ -> Atoll.OAuth.Permissions.describe(scope)
    end
  end

  defp set_title(scope, request, conn) do
    case Atoll.OAuth.PermissionSnapshots.entry(scope, request.permission_sets) do
      {:ok, entry} -> translated(entry, "title", conn)
      _ -> nil
    end
  end

  defp set_details(scope, request, conn) do
    case Atoll.OAuth.PermissionSnapshots.entry(scope, request.permission_sets) do
      {:ok, entry} ->
        detail = translated(entry, "detail", conn) || ""

        permissions =
          Enum.map_join(entry["scopes"], "", fn value ->
            "<li>" <> e(Atoll.OAuth.Permissions.describe(value)) <> "</li>"
          end)

        "<details><summary>View included permissions</summary><p>" <>
          e(detail) <>
          "</p><p>" <>
          e(scope) <>
          "</p><ul>" <>
          permissions <>
          "</ul><p>This set can change over time within its namespace. You can revoke this application from your account.</p></details>"

      _ ->
        ""
    end
  end

  defp translated(entry, field, conn) do
    translations = entry[field <> ":lang"] || %{}
    languages = get_req_header(conn, "accept-language") |> List.first() || ""

    preferences =
      if byte_size(languages) <= 1024 do
        languages
        |> String.split(",")
        |> Enum.take(16)
        |> Enum.flat_map(fn part ->
          case String.split(String.trim(part), ";q=", parts: 2) do
            [language] ->
              [{String.downcase(language), 1.0}]

            [language, quality] ->
              case Float.parse(quality) do
                {q, ""} when q > 0 and q <= 1 -> [{String.downcase(language), q}]
                _ -> []
              end
          end
        end)
        |> Enum.sort_by(fn {_, q} -> -q end)
      else
        []
      end

    Enum.find_value(preferences, fn {language, _} ->
      parts = String.split(language, "-")

      Enum.find_value(length(parts)..1//-1, fn n ->
        wanted = Enum.take(parts, n) |> Enum.join("-")

        Enum.find_value(translations, fn {tag, text} ->
          if String.downcase(tag) == wanted, do: text
        end)
      end)
    end) || entry[field]
  end

  defp transport,
    do:
      Application.get_env(:atoll, :oauth_transport_options, [])
      |> Keyword.take([:request, :lookup])

  defp e(value), do: Plug.HTML.html_escape(value)
  defp go(conn, url), do: conn |> put_resp_header("location", url) |> send_resp(303, "")
end
