defmodule AtollWeb.RecordWriteController do
  use AtollWeb, :controller
  action_fallback AtollWeb.XRPCFallback

  def create(conn, _params), do: write(conn, :create)
  def put(conn, _params), do: write(conn, :put)
  def delete(conn, _params), do: write(conn, :delete)

  defp write(%{private: %{atoll_record_token: token}} = conn, action) do
    with {:ok, result} <- Atoll.Repositories.Writes.write(token, action, conn.body_params),
         do: json(conn, result)
  end

  defp write(_, _), do: {:error, :auth_required}
end
