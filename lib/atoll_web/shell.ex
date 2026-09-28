defmodule AtollWeb.Shell do
  @moduledoc """
  Renders the React account frontend: an empty root, the screen's data as JSON,
  and a no-script fallback form so the flows still work without the bundle.

  Screen payloads are documented in `assets/src/bootstrap.ts`; messages are sent
  as codes and translated in the browser.
  """

  import Plug.Conn

  def render(conn, status, data) do
    payload =
      data
      |> Map.put_new(:error, "")
      |> Map.put_new(:notice, "")
      |> Map.put_new_lazy(:csrf, fn -> csrf_token(data) end)
      |> Map.put(:service, service_host())

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, document(payload))
  end

  def message(conn, status, code, link \\ %{href: "/account/login", label: "signIn"}) do
    render(conn, status, %{
      screen: "message",
      title: "Atoll",
      text: code,
      error: code,
      link: link
    })
  end

  # Screens without a form must not mint a token: error pages can be rendered
  # before the session plug runs.
  defp csrf_token(%{screen: screen})
       when screen in ~w(login signup authorize sessions security passkeys),
       do: Plug.CSRFProtection.get_csrf_token()

  defp csrf_token(_), do: ""

  defp document(payload) do
    """
    <!doctype html><html lang="en"><head><meta charset="utf-8">\
    <meta name="viewport" content="width=device-width,initial-scale=1">\
    <title>#{e(payload.title)}</title>\
    <link rel="icon" href="/favicon.ico" sizes="any">\
    <link rel="stylesheet" href="#{e(static("/assets/account.css"))}">\
    <script type="module" src="#{e(static("/assets/account.js"))}" defer></script>\
    </head><body><div id="root"></div>\
    <script type="application/json" id="atoll-bootstrap">#{json(payload)}</script>\
    <noscript>#{noscript(payload)}</noscript>\
    </body></html>\
    """
  end

  defp json(payload), do: Jason.encode!(payload, escape: :html_safe)

  defp static(path), do: AtollWeb.Endpoint.static_path(path)

  defp service_host, do: URI.parse(AtollWeb.Endpoint.url()).host

  defp noscript(%{screen: "login"} = payload) do
    form("/account/login", payload.csrf, """
    <label>Username or email address<input name="identifier" value="#{e(payload.identifier)}" autocomplete="username" required maxlength="2048"></label>
    <label>Password<input type="password" name="password" autocomplete="current-password" required maxlength="1024"></label>
    <label>Email sign-in code (if requested)<input name="authFactorToken" maxlength="32"></label>
    <label>Authenticator code (if enabled)<input name="totpCode" maxlength="26"></label>
    <button type="submit">Sign in</button>
    """)
  end

  defp noscript(%{screen: "signup"} = payload) do
    invite =
      if payload.inviteRequired,
        do: ~s(<label>Invitation code<input name="inviteCode" required maxlength="256"></label>),
        else: ""

    view =
      if payload.view,
        do: ~s(<input type="hidden" name="view" value="#{e(payload.view)}">),
        else: ""

    form("/account/signup", payload.csrf, """
    #{view}
    <label>Username<input name="handle" value="#{e(payload.handle)}" autocomplete="username" required maxlength="253"></label>
    <label>Email (optional)<input type="email" name="email" autocomplete="email" maxlength="320"></label>
    <label>Password<input type="password" name="password" autocomplete="new-password" required minlength="8" maxlength="1024"></label>
    #{invite}
    <button type="submit" name="action" value="create">Create account</button>
    """)
  end

  defp noscript(%{screen: "authorize"} = payload) do
    choices =
      Enum.map_join(payload.permissions, "", fn permission ->
        checked = if permission.checked, do: " checked", else: ""

        ~s(<label><input type="checkbox" name="#{e(permission.field)}" value="yes"#{checked}> #{e(permission.title)}</label>)
      end)

    form("/oauth/authorize", payload.csrf, """
    <input type="hidden" name="view" value="#{e(payload.view)}">
    #{choices}
    <button type="submit" name="decision" value="approve">Authorize</button>
    <button type="submit" name="decision" value="deny">Deny access</button>
    """)
  end

  defp noscript(_), do: "<p>This page needs JavaScript. Password sign-in remains available.</p>"

  defp form(action, csrf, fields) do
    ~s(<form method="post" action="#{e(action)}"><input type="hidden" name="_csrf_token" value="#{e(csrf)}">#{fields}</form>)
  end

  defp e(nil), do: ""
  defp e(value) when is_binary(value), do: Plug.HTML.html_escape(value)
  defp e(value), do: value |> to_string() |> Plug.HTML.html_escape()
end
