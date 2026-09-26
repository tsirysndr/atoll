defmodule AtollWeb.SessionController do
  use AtollWeb, :controller
  alias Atoll.Accounts.Sessions
  action_fallback AtollWeb.SessionFallback

  def reserve_signing_key(conn, _) do
    with {:ok, result} <- Atoll.Accounts.SigningKeyReservations.request(conn.body_params),
         do: json(conn, result)
  end

  def invite_codes(conn, params) do
    with {:ok, token} <- bearer(conn),
         {:ok, result} <- Atoll.Accounts.InviteListing.account(token, params),
         do: json(conn, result)
  end

  def request_email_confirmation(conn, _params) do
    with {:ok, token} <- bearer(conn),
         {:ok, _} <- Atoll.Accounts.EmailConfirmation.request(token),
         do: send_resp(conn, 200, "")
  end

  def confirm_email(conn, _params) do
    with {:ok, token} <- bearer(conn),
         {:ok, _} <- Atoll.Accounts.EmailConfirmation.confirm(token, conn.body_params),
         do: send_resp(conn, 200, "")
  end

  def request_email_update(conn, _params) do
    with {:ok, token} <- bearer(conn),
         {:ok, result} <- Atoll.Accounts.EmailUpdate.request(token),
         do: json(conn, result)
  end

  def update_email(conn, _params) do
    with {:ok, token} <- bearer(conn),
         {:ok, _} <- Atoll.Accounts.EmailUpdate.update(token, conn.body_params),
         do: send_resp(conn, 200, "")
  end

  def request_password_reset(conn, _params) do
    with {:ok, _} <- Atoll.Accounts.PasswordReset.request(conn.body_params),
         do: send_resp(conn, 200, "")
  end

  def reset_password(conn, _params) do
    with {:ok, _} <- Atoll.Accounts.PasswordReset.reset(conn.body_params),
         do: send_resp(conn, 200, "")
  end

  def create_app_password(conn, _params) do
    with {:ok, token} <- bearer(conn),
         {:ok, result} <- Atoll.Accounts.AppPasswords.create(token, conn.body_params),
         do: json(conn, result)
  end

  def list_app_passwords(conn, _params) do
    with {:ok, token} <- bearer(conn),
         {:ok, result} <- Atoll.Accounts.AppPasswords.list(token),
         do: json(conn, result)
  end

  def revoke_app_password(conn, _params) do
    with {:ok, token} <- bearer(conn),
         {:ok, _} <- Atoll.Accounts.AppPasswords.revoke(token, conn.body_params),
         do: send_resp(conn, 200, "")
  end

  def request_account_delete(conn, _params) do
    with {:ok, token} <- bearer(conn),
         {:ok, _} <- Atoll.Accounts.Deletion.request(token),
         do: send_resp(conn, 200, "")
  end

  def delete_account(conn, _params) do
    with {:ok, _} <- Atoll.Accounts.Deletion.delete(conn.body_params),
         do: send_resp(conn, 200, "")
  end

  def create_account(conn, _params) do
    result =
      if Map.has_key?(conn.body_params, "did") do
        with {:ok, token} <- bearer(conn),
             do: Atoll.Accounts.Provisioning.import_account(token, conn.body_params)
      else
        opts =
          Keyword.merge(
            Application.get_env(:atoll, :identity_resolution_options, []),
            Application.get_env(:atoll, :plc_submission_options, [])
          )

        Atoll.Accounts.Signup.create(conn.body_params, opts)
      end

    with {:ok, account} <- result, do: json(conn, account)
  end

  def create(conn, _params) do
    with {:ok, identifier, password, opts} <- credentials(conn.body_params),
         {:ok, pair, handle} <- login_pair(identifier, password, opts) do
      result = session_response(pair)
      json(conn, if(handle, do: Map.put(result, :handle, handle), else: result))
    end
  end

  def show(conn, _params) do
    if AtollWeb.OAuthResource.attempt?(conn) do
      AtollWeb.OAuthResource.read(conn, fn principal ->
        result = identity(principal)

        if "transition:email" in String.split(principal.scope, " "),
          do: Map.delete(result, :emailAuthFactor),
          else: Map.drop(result, [:email, :emailConfirmed, :emailAuthFactor])
      end)
    else
      with {:ok, token} <- bearer(conn),
           {:ok, head} <- Sessions.authenticate_session(token) do
        json(conn, identity(head))
      end
    end
  end

  def status(conn, _params) do
    with {:ok, token} <- bearer(conn),
         {:ok, status} <- Atoll.Accounts.Status.get(token) do
      json(conn, status)
    end
  end

  def service_auth(conn, params) do
    if AtollWeb.OAuthResource.attempt?(conn) do
      case AtollWeb.OAuthResource.read_result(
             conn,
             &Atoll.Accounts.ServiceAuth.issue_oauth(&1, params),
             required_scopes: ["transition:generic"]
           ) do
        {:ok, {:ok, result}} ->
          json(conn, result)

        {:ok, {:error, :insufficient_scope}} ->
          AtollWeb.OAuthResource.error(conn, :insufficient_scope)

        {:ok, error} ->
          error

        {:error, conn} ->
          conn
      end
    else
      with {:ok, token} <- bearer(conn),
           {:ok, result} <- Atoll.Accounts.ServiceAuth.issue(token, params) do
        json(conn, result)
      end
    end
  end

  def refresh(conn, _params) do
    with {:ok, token} <- bearer(conn),
         {:ok, pair} <- Sessions.refresh(token) do
      json(conn, session_response(pair))
    end
  end

  def delete(conn, _params) do
    with {:ok, token} <- bearer(conn), :ok <- revoke(token) do
      send_resp(conn, 200, "")
    end
  end

  def activate(conn, _params) do
    with {:ok, token} <- bearer(conn),
         {:ok, _} <- Atoll.Accounts.Lifecycle.activate(token),
         do: send_resp(conn, 200, "")
  end

  def deactivate(conn, _params) do
    with {:ok, token} <- bearer(conn),
         {:ok, _} <- Atoll.Accounts.Lifecycle.deactivate(token, conn.body_params),
         do: send_resp(conn, 200, "")
  end

  defp revoke(token) do
    case Sessions.revoke(token) do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  defp credentials(%{"identifier" => identifier, "password" => password} = body)
       when is_binary(identifier) and is_binary(password) do
    if (Atoll.Syntax.did?(identifier) or Atoll.Syntax.handle?(identifier) or
          match?({:ok, _}, Atoll.Accounts.EmailAddress.normalize(identifier))) and
         byte_size(password) in 8..1024 and String.valid?(password) and
         is_boolean(Map.get(body, "allowTakendown", false)) and
         valid_factor?(Map.get(body, "authFactorToken")) and valid_totp?(body["totpCode"]),
       do:
         {:ok, identifier, password,
          [
            auth_factor_token: body["authFactorToken"],
            totp_code: body["totpCode"],
            allow_takendown: Map.get(body, "allowTakendown", false)
          ]},
       else: {:error, :invalid_request}
  end

  defp credentials(_), do: {:error, :invalid_request}

  defp valid_totp?(nil), do: true
  defp valid_totp?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9]{6}\z/, value)
  defp valid_totp?(_), do: false

  defp valid_factor?(nil), do: true
  defp valid_factor?(token) when is_binary(token), do: byte_size(token) == 32
  defp valid_factor?(_), do: false

  defp login_pair(identifier, password, opts) do
    if String.contains?(identifier, "@") do
      with {:ok, pair} <- Sessions.create_email(identifier, password, opts),
           do: {:ok, pair, nil}
    else
      with {:ok, did, handle} <- login_identity(identifier),
           {:ok, pair} <- Sessions.create(did, password, opts),
           do: {:ok, pair, handle}
    end
  end

  defp login_identity(identifier) do
    if Atoll.Syntax.did?(identifier) do
      {:ok, identifier, nil}
    else
      opts =
        Application.get_env(:atoll, :identity_resolution_options, [])
        |> Keyword.put(:force_refresh, true)

      case Atoll.Identity.Handle.verify(identifier, opts) do
        {:ok, identity} -> {:ok, identity.did, identity.handle}
        {:error, _} -> {:error, :invalid_credentials}
      end
    end
  end

  defp bearer(conn), do: AtollWeb.BearerToken.get(conn)

  defp session_response(pair) do
    Map.merge(identity(pair), %{accessJwt: pair.access_jwt, refreshJwt: pair.refresh_jwt})
  end

  defp identity(%{did: did, status: status}) do
    observation = Atoll.Repo.get(Atoll.Identity.Observation, did)
    profile = Atoll.Repo.get(Atoll.Accounts.Profile, did)

    result = %{
      did: did,
      handle:
        cond do
          observation -> observation.handle
          profile -> profile.handle
          true -> "handle.invalid"
        end,
      active: status == :active
    }

    result =
      if profile && profile.email,
        do:
          Map.merge(result, %{
            email: profile.email,
            emailConfirmed: not is_nil(profile.email_confirmed_at),
            emailAuthFactor: profile.email_auth_factor
          }),
        else: result

    if status == :active, do: result, else: Map.put(result, :status, Atom.to_string(status))
  end
end
