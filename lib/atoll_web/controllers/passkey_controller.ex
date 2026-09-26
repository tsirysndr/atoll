defmodule AtollWeb.PasskeyController do
  use AtollWeb, :controller
  alias Atoll.Accounts.{Passkeys, Sessions}
  alias AtollWeb.AccountController, as: UI

  def dispatch(%{method: "GET"} = conn, "/account/passkeys") do
    if map_size(conn.query_params) == 0, do: show(conn), else: error(conn, :invalid_request)
  end

  def dispatch(conn, "/account/passkeys/register/begin") do
    p = conn.body_params

    with true <- fields?(p, ~w(_csrf_token name password totpCode)),
         binding = random(),
         {:ok, request} <-
           Passkeys.begin_registration(token(conn), p["password"], binding, p["name"],
             totp_code: p["totpCode"]
           ) do
      ceremony(conn, "register", binding, request)
    else
      false -> error(conn, :invalid_request)
      {:error, reason} -> error(conn, reason)
    end
  end

  def dispatch(conn, "/account/passkeys/login/begin") do
    if get_session(conn, :account_access) do
      go(conn, "/account/sessions")
    else
      with true <- fields?(conn.body_params, ~w(_csrf_token)),
           binding = random(),
           {:ok, request} <- Passkeys.begin_login(binding) do
        ceremony(conn, "login", binding, request)
      else
        false -> error(conn, :invalid_request)
        {:error, reason} -> error(conn, reason)
      end
    end
  end

  def dispatch(conn, "/account/passkeys/" <> kind_and_action)
      when kind_and_action in ["register/finish", "login/finish"] do
    kind = if kind_and_action == "register/finish", do: "register", else: "login"
    pending = get_session(conn, :passkey_pending)
    conn = delete_session(conn, :passkey_pending)

    with true <- fields?(conn.body_params, ~w(_csrf_token credential)),
         %{"kind" => ^kind, "reference" => reference, "binding" => binding} <- pending,
         {:ok, response} <- credential(conn.body_params["credential"], kind),
         {:ok, result} <- complete(conn, kind, binding, reference, response) do
      if kind == "login", do: UI.signed_in(conn, result), else: go(conn, "/account/passkeys")
    else
      {:error, reason} -> error(conn, reason)
      _ -> error(conn, :invalid_passkey)
    end
  end

  def dispatch(conn, "/account/passkeys/revoke") do
    p = conn.body_params

    with true <- fields?(p, ~w(_csrf_token id password totpCode)),
         {:ok, :revoked} <-
           Passkeys.revoke(token(conn), p["password"], p["id"], totp_code: p["totpCode"]) do
      # Removing the current login key also revokes this browser's session.
      case Sessions.authenticate_management(token(conn)) do
        {:ok, _} -> go(conn, "/account/passkeys")
        _ -> signed_out(conn)
      end
    else
      false -> error(conn, :invalid_request)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp complete(conn, "register", binding, reference, response),
    do: Passkeys.complete_registration(token(conn), binding, reference, response)

  defp complete(conn, "login", binding, reference, response) do
    if token(conn),
      do: {:error, :invalid_request},
      else: Passkeys.complete_login(binding, reference, response)
  end

  defp ceremony(conn, kind, binding, request) do
    conn =
      conn
      |> put_session(:passkey_pending, %{
        "kind" => kind,
        "binding" => binding,
        "reference" => request.reference
      })
      |> put_resp_header(
        "content-security-policy",
        "default-src 'none'; script-src 'self'; style-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
      )
      |> put_resp_header(
        "permissions-policy",
        "publickey-credentials-create=(self), publickey-credentials-get=(self)"
      )
      |> assign(:passkey_script, true)

    title = if kind == "register", do: "Save your passkey", else: "Sign in with a passkey"

    UI.page(
      conn,
      200,
      title,
      "<p>Use your device’s screen lock or a security key to continue. This request expires in five minutes.</p>" <>
        "<p id=\"passkey-status\" role=\"status\" aria-live=\"polite\"></p><noscript><p>Passkeys require JavaScript. Password sign-in remains available.</p></noscript>" <>
        "<form method=\"post\" action=\"/account/passkeys/" <>
        kind <>
        "/finish\" data-passkey-ceremony=\"" <>
        kind <>
        "\" data-public-key=\"" <>
        e(Jason.encode!(request.public_key)) <>
        "\">" <>
        csrf() <>
        "<input type=\"hidden\" name=\"credential\"><button type=\"button\">Continue with passkey</button></form>" <>
        back(kind)
    )
  end

  defp show(conn) do
    case Passkeys.list(token(conn)) do
      {:ok, keys} ->
        rows =
          Enum.map_join(keys, "", fn key ->
            "<li><strong>" <>
              e(key.name) <>
              "</strong><p>Added " <>
              date(key.created_at) <>
              "; last used " <>
              date(key.last_used_at) <>
              ".</p>" <>
              "<details><summary>Remove this passkey</summary><p>This signs out sessions and disconnects applications authorized with this passkey.</p>" <>
              "<form method=\"post\" action=\"/account/passkeys/revoke\">" <>
              csrf() <>
              "<input type=\"hidden\" name=\"id\" value=\"" <>
              e(key.id) <>
              "\">" <>
              password_fields() <>
              "<button>Remove passkey</button></form></details></li>"
          end)

        enroll =
          if Passkeys.enabled?(),
            do:
              "<h2>Add a passkey</h2><form method=\"post\" action=\"/account/passkeys/register/begin\">" <>
                csrf() <>
                "<label>Passkey name<input name=\"name\" required maxlength=\"64\" autocomplete=\"off\" placeholder=\"e.g. Personal laptop\"></label>" <>
                password_fields() <> "<button>Add passkey</button></form>",
            else: "<p>New passkey setup and sign-in are disabled on this server.</p>"

        UI.page(
          conn,
          200,
          "Your passkeys",
          "<p>Passkeys let you sign in using your device’s screen lock or a security key, without a password or authenticator code.</p>" <>
            if(rows == "",
              do: "<p>You have no passkeys yet.</p>",
              else: "<ul>" <> rows <> "</ul>"
            ) <>
            enroll <>
            "<h2>Lost a passkey?</h2><p>Sign in with your password and any enabled email or authenticator factor. Then remove the lost passkey here and add a replacement. Keep a spare passkey or your authenticator recovery codes somewhere safe.</p>" <>
            back()
        )

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp credential(raw, kind) when is_binary(raw) and byte_size(raw) <= 40_000 do
    with {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(raw, objects: :ordered_objects),
         {:ok, outer} <- object(pairs, ~w(id rawId type response)),
         %Jason.OrderedObject{values: fields} <- outer["response"],
         {:ok, response} <-
           object(
             fields,
             if(kind == "register",
               do: ~w(clientDataJSON attestationObject),
               else: ~w(clientDataJSON authenticatorData signature userHandle)
             )
           ),
         true <- Enum.all?(response, fn {_, value} -> is_binary(value) end),
         true <- Enum.all?(~w(id rawId type), &is_binary(outer[&1])) do
      {:ok, Map.put(outer, "response", response)}
    else
      _ -> {:error, :invalid_passkey}
    end
  end

  defp credential(_, _), do: {:error, :invalid_passkey}

  defp object(pairs, fields) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if Enum.sort(keys) == Enum.sort(fields),
      do: {:ok, Map.new(pairs)},
      else: {:error, :invalid_passkey}
  end

  defp error(conn, reason) do
    cond do
      reason in [:invalid_token, :expired_token, :forbidden] ->
        signed_out(conn)

      reason in [
        :passkey_store_unavailable,
        :passkey_challenge_capacity,
        :session_configuration_missing,
        :key_vault_unconfigured,
        :key_decryption_failed
      ] ->
        notice(conn, 503, "Passkeys are temporarily unavailable. Try again later.")

      reason == :totp_rate_limited ->
        conn
        |> put_resp_header("retry-after", "300")
        |> notice(429, "Too many authenticator attempts. Try again in five minutes.")

      reason in [:totp_required, :invalid_totp] ->
        notice(
          conn,
          401,
          "Enter an unused authenticator or recovery code with your account password."
        )

      reason == :invalid_credentials ->
        notice(conn, 401, "Your account password was not accepted.")

      reason == :passkeys_disabled ->
        notice(
          conn,
          403,
          "Passkey setup and sign-in are disabled. You can still use your password."
        )

      reason == :passkey_limit ->
        notice(conn, 400, "You can have up to ten passkeys. Remove one before adding another.")

      true ->
        notice(
          conn,
          400,
          "The passkey request could not complete. Restart setup or sign-in and try again."
        )
    end
  end

  defp notice(conn, status, text),
    do:
      UI.page(
        conn,
        status,
        "Passkeys",
        "<p>" <> e(text) <> "</p>" <> back(if(token(conn), do: "register", else: "login"))
      )

  defp password_fields,
    do:
      "<label>Account password<input type=\"password\" name=\"password\" autocomplete=\"current-password\" required minlength=\"8\" maxlength=\"1024\"></label>" <>
        "<label>Authenticator or recovery code (if enabled)<input name=\"totpCode\" autocomplete=\"one-time-code\" maxlength=\"26\" pattern=\"([0-9]{6}|[A-Z2-7]{26})\"></label>"

  defp csrf,
    do:
      "<input type=\"hidden\" name=\"_csrf_token\" value=\"" <>
        e(Plug.CSRFProtection.get_csrf_token()) <> "\">"

  defp back,
    do:
      "<p><a href=\"/account/security\">Account security</a> · <a href=\"/account/sessions\">Connected applications</a></p>"

  defp back("register"), do: "<p><a href=\"/account/passkeys\">Back to passkeys</a></p>"
  defp back("login"), do: "<p><a href=\"/account/login\">Use password instead</a></p>"

  defp fields?(params, allowed), do: Map.keys(params) -- allowed == []

  defp token(conn), do: get_session(conn, :account_access)
  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp date(nil), do: "never"
  defp date(seconds), do: DateTime.from_unix!(seconds) |> DateTime.to_iso8601() |> e()
  defp e(value), do: Plug.HTML.html_escape(value)
  defp go(conn, path), do: conn |> put_resp_header("location", path) |> send_resp(303, "")

  defp signed_out(conn) do
    Plug.CSRFProtection.delete_csrf_token()
    conn |> clear_session() |> configure_session(drop: true) |> go("/account/login")
  end
end
