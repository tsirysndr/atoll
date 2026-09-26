defmodule AtollWeb.SessionController do
  use AtollWeb, :controller
  alias Atoll.Accounts.Sessions
  action_fallback AtollWeb.SessionFallback

  def create(conn, _params) do
    with {:ok, identifier, password} <- credentials(conn.body_params),
         {:ok, did, handle} <- login_identity(identifier),
         {:ok, pair} <- Sessions.create(did, password) do
      result = session_response(pair)
      json(conn, if(handle, do: Map.put(result, :handle, handle), else: result))
    end
  end

  def show(conn, _params) do
    with {:ok, token} <- bearer(conn),
         {:ok, %{did: did}} <- Sessions.authenticate(token) do
      json(conn, identity(did))
    end
  end

  def status(conn, _params) do
    with {:ok, token} <- bearer(conn),
         {:ok, status} <- Atoll.Accounts.Status.get(token) do
      json(conn, status)
    end
  end

  def service_auth(conn, params) do
    with {:ok, token} <- bearer(conn),
         {:ok, result} <- Atoll.Accounts.ServiceAuth.issue(token, params) do
      json(conn, result)
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

  defp revoke(token) do
    case Sessions.revoke(token) do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  defp credentials(%{"identifier" => identifier, "password" => password} = body)
       when is_binary(identifier) and is_binary(password) do
    if (Atoll.Syntax.did?(identifier) or Atoll.Syntax.handle?(identifier)) and
         byte_size(password) in 8..1024 and String.valid?(password) and
         Map.get(body, "allowTakendown", false) == false and
         not Map.has_key?(body, "authFactorToken"),
       do: {:ok, identifier, password},
       else: {:error, :invalid_request}
  end

  defp credentials(_), do: {:error, :invalid_request}

  defp login_identity(identifier) do
    if Atoll.Syntax.did?(identifier) do
      {:ok, identifier, nil}
    else
      opts = Application.get_env(:atoll, :identity_resolution_options, [])

      case Atoll.Identity.Handle.verify(identifier, opts) do
        {:ok, identity} -> {:ok, identity.did, identity.handle}
        {:error, _} -> {:error, :invalid_credentials}
      end
    end
  end

  defp bearer(conn), do: AtollWeb.BearerToken.get(conn)

  defp session_response(pair) do
    Map.merge(identity(pair.did), %{accessJwt: pair.access_jwt, refreshJwt: pair.refresh_jwt})
  end

  defp identity(did) do
    observation = Atoll.Repo.get(Atoll.Identity.Observation, did)

    %{
      did: did,
      handle: if(observation, do: observation.handle, else: "handle.invalid"),
      active: true
    }
  end
end
