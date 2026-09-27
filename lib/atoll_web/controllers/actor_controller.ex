defmodule AtollWeb.ActorController do
  use AtollWeb, :controller
  alias Atoll.Accounts.Preferences
  action_fallback AtollWeb.XRPCFallback

  def get_preferences(conn, _params) do
    if AtollWeb.OAuthResource.attempt?(conn) do
      case AtollWeb.OAuthResource.read_result(conn, &Preferences.oauth_get/1) do
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
      with {:ok, token} <- AtollWeb.BearerToken.get(conn),
           {:ok, result} <- Preferences.get(token),
           do: json(conn, result)
    end
  end

  def put_preferences(conn, _params) do
    credential =
      case conn.private[:atoll_preferences_credential] do
        %Atoll.OAuth.WriteCredential{} = credential -> {:ok, credential}
        _ -> AtollWeb.BearerToken.get(conn)
      end

    with {:ok, token} <- credential do
      case Preferences.put(token, conn.body_params) do
        {:ok, _} ->
          send_resp(conn, 200, "")

        {:error, reason} = error
        when reason in [:invalid_token, :insufficient_scope, :oauth_resource_store_unavailable] ->
          if match?(%Atoll.OAuth.WriteCredential{}, token),
            do: AtollWeb.OAuthResource.error(conn, reason),
            else: error

        error ->
          error
      end
    end
  end
end
