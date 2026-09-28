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

    AtollWeb.Shell.render(conn, 200, %{
      screen: "passkeys",
      title: if(kind == "register", do: "Save your passkey", else: "Sign in with a passkey"),
      passkeys: [],
      enabled: Passkeys.enabled?(),
      ceremony: %{
        kind: kind,
        action: "/account/passkeys/" <> kind <> "/finish",
        publicKey: request.public_key
      }
    })
  end

  defp show(conn, error \\ "", status \\ 200) do
    case Passkeys.list(token(conn)) do
      {:ok, keys} ->
        AtollWeb.Shell.render(conn, status, %{
          screen: "passkeys",
          title: "Passkeys",
          error: error,
          enabled: Passkeys.enabled?(),
          ceremony: nil,
          passkeys:
            Enum.map(keys, fn key ->
              %{
                id: key.id,
                name: key.name,
                createdAt: timestamp(key.created_at),
                lastUsedAt: timestamp(key.last_used_at)
              }
            end)
        })

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
        notice(conn, 503, "passkeys_unavailable")

      reason == :totp_rate_limited ->
        conn
        |> put_resp_header("retry-after", "300")
        |> notice(429, "totp_rate_limited")

      reason in [:totp_required, :invalid_totp] ->
        notice(conn, 401, "totp_required")

      reason == :invalid_credentials ->
        notice(conn, 401, "invalid_credentials")

      reason == :passkeys_disabled ->
        notice(conn, 403, "passkeys_disabled")

      reason == :passkey_limit ->
        notice(conn, 400, "passkey_limit")

      true ->
        notice(conn, 400, "passkey_failed")
    end
  end

  defp notice(conn, status, code) do
    if token(conn),
      do: show(conn, code, status),
      else: UI.message(conn, status, code)
  end

  defp fields?(params, allowed), do: Map.keys(params) -- allowed == []

  defp timestamp(nil), do: nil
  defp timestamp(seconds), do: DateTime.from_unix!(seconds) |> DateTime.to_iso8601()

  defp token(conn), do: get_session(conn, :account_access)
  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp go(conn, path), do: conn |> put_resp_header("location", path) |> send_resp(303, "")

  defp signed_out(conn) do
    Plug.CSRFProtection.delete_csrf_token()
    conn |> clear_session() |> configure_session(drop: true) |> go("/account/login")
  end
end
