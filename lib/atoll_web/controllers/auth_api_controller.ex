defmodule AtollWeb.AuthApiController do
  @moduledoc """
  `social.rocksky.auth.*`: two-factor and passkeys as XRPC methods.

  The atproto lexicon defines neither, so this server grew a browser interface
  for them — form-encoded, authorised by a session cookie, answered with HTML.
  That cannot be shared: a client would have to know which implementation it is
  talking to, and a token-based client cannot use it at all.

  These endpoints put the same machinery behind the shared contract, authorised
  by the bearer token every other XRPC method uses. The browser interface is
  untouched; this is an additional way in, not a replacement.
  """
  use AtollWeb, :controller

  alias Atoll.Accounts.{Authenticator, Passkeys}
  alias AtollWeb.BearerToken

  action_fallback AtollWeb.AuthApiFallback

  def two_factor(conn, _params) do
    with {:ok, token} <- BearerToken.get(conn),
         {:ok, factor} <- Authenticator.status(token) do
      json(conn, %{
        state: to_string(factor.state),
        recoveryRemaining: Map.get(factor, :recovery_remaining, 0)
      })
    end
  end

  def begin_two_factor(conn, params) do
    with {:ok, token} <- BearerToken.get(conn),
         {:ok, password} <- field(params, "password"),
         {:ok, enrollment} <- Authenticator.begin(token, password, issuer()) do
      json(conn, %{state: "pending", secret: enrollment.secret, uri: Map.get(enrollment, :uri)})
    end
  end

  def confirm_two_factor(conn, params) do
    with {:ok, token} <- BearerToken.get(conn),
         {:ok, code} <- field(params, "code"),
         {:ok, %{recovery_codes: codes}} <- Authenticator.confirm(token, code) do
      json(conn, %{state: "enabled", recoveryCodes: codes})
    end
  end

  def disable_two_factor(conn, params) do
    with {:ok, token} <- BearerToken.get(conn),
         {:ok, password} <- field(params, "password"),
         {:ok, code} <- field(params, "code"),
         {:ok, :disabled} <- Authenticator.disable(token, password, code) do
      json(conn, %{state: "disabled"})
    end
  end

  def regenerate_recovery_codes(conn, params) do
    with {:ok, token} <- BearerToken.get(conn),
         {:ok, password} <- field(params, "password"),
         {:ok, code} <- field(params, "code"),
         {:ok, %{recovery_codes: codes}} <- Authenticator.regenerate(token, password, code) do
      json(conn, %{recoveryCodes: codes})
    end
  end

  def list_passkeys(conn, _params) do
    with {:ok, token} <- BearerToken.get(conn),
         {:ok, rows} <- Passkeys.list(token) do
      json(conn, %{passkeys: Enum.map(rows, &passkey/1)})
    end
  end

  def begin_passkey_registration(conn, params) do
    # The server picks the binding and returns it inside the opaque requestId.
    # There is no cookie to hold it, and the ceremony is claimed with both
    # halves, so only the caller that started one can finish it.
    browser = new_binding()

    with {:ok, token} <- BearerToken.get(conn),
         {:ok, password} <- field(params, "password"),
         name = Map.get(params, "name") || "passkey",
         {:ok, request} <-
           Passkeys.begin_registration(token, password, browser, name,
             totp_code: Map.get(params, "code")
           ) do
      json(conn, %{
        requestId: request_id(request.reference, browser),
        publicKey: request.public_key
      })
    end
  end

  def finish_passkey_registration(conn, params) do
    with {:ok, token} <- BearerToken.get(conn),
         {:ok, raw} <- field(params, "requestId"),
         {:ok, {reference, browser}} <- split_request_id(raw),
         {:ok, credential} <- field(params, "credential"),
         {:ok, result} <- Passkeys.complete_registration(token, browser, reference, credential) do
      json(conn, %{passkey: passkey(result)})
    end
  end

  # --- signing in with a passkey -------------------------------------------
  # Unauthenticated by design: these are how a session begins.

  def begin_passkey_login(conn, _params) do
    browser = new_binding()

    with {:ok, request} <- Passkeys.begin_login(browser) do
      json(conn, %{
        requestId: request_id(request.reference, browser),
        publicKey: request.public_key
      })
    end
  end

  def finish_passkey_login(conn, params) do
    with {:ok, raw} <- field(params, "requestId"),
         {:ok, {reference, browser}} <- split_request_id(raw),
         {:ok, credential} <- field(params, "credential"),
         {:ok, pair} <- Passkeys.complete_login(browser, reference, credential) do
      json(conn, AtollWeb.SessionController.session_payload(pair))
    end
  end

  def delete_passkey(conn, params) do
    with {:ok, token} <- BearerToken.get(conn),
         {:ok, password} <- field(params, "password"),
         {:ok, id} <- field(params, "id"),
         {:ok, _} <- Passkeys.revoke(token, password, id) do
      json(conn, %{})
    end
  end

  # --- shaping -------------------------------------------------------------

  defp passkey(row) when is_map(row) do
    %{id: to_string(row[:id] || row["id"])}
    |> put_present(:name, row[:name] || row["name"])
    |> put_present(:createdAt, stamp(row[:created_at] || row["created_at"]))
    |> put_present(:lastUsedAt, stamp(row[:last_used_at] || row["last_used_at"]))
  end

  defp passkey(other), do: %{id: to_string(other)}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp stamp(nil), do: nil
  defp stamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stamp(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  # Passkey rows keep Unix seconds. Printed bare, a browser reads "1790879337"
  # as the year 1790.
  defp stamp(value) when is_integer(value),
    do: value |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp stamp(value), do: to_string(value)

  defp field(params, name) do
    case Map.get(params, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end

  defp issuer, do: URI.parse(AtollWeb.Endpoint.url()).host || "Atoll"

  defp new_binding, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp request_id(reference, browser), do: "#{reference}.#{browser}"

  defp split_request_id(value) do
    case String.split(value, ".", parts: 2) do
      [reference, browser] when reference != "" and browser != "" -> {:ok, {reference, browser}}
      # An empty half is not a usable half: refuse rather than pass it on.
      _ -> {:error, :invalid_passkey}
    end
  end
end
