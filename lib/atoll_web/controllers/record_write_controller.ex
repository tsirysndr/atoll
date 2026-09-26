defmodule AtollWeb.RecordWriteController do
  use AtollWeb, :controller
  action_fallback AtollWeb.XRPCFallback

  def create(conn, _params), do: write(conn, :create)
  def put(conn, _params), do: write(conn, :put)
  def delete(conn, _params), do: write(conn, :delete)

  def batch(%{private: %{atoll_record_token: token}} = conn, _params) do
    respond(conn, token, Atoll.Repositories.Writes.batch(token, conn.body_params))
  end

  def batch(_, _), do: {:error, :auth_required}

  defp write(%{private: %{atoll_record_token: token}} = conn, action) do
    respond(conn, token, Atoll.Repositories.Writes.write(token, action, conn.body_params))
  end

  defp write(_, _), do: {:error, :auth_required}

  defp respond(conn, _, {:ok, result}), do: json(conn, result)

  defp respond(conn, %Atoll.OAuth.WriteCredential{}, {:error, reason})
       when reason in [:invalid_token, :insufficient_scope, :oauth_resource_store_unavailable],
       do: AtollWeb.OAuthResource.error(conn, reason)

  defp respond(_, _, error), do: error
end
