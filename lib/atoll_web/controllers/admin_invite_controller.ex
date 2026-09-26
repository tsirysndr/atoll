defmodule AtollWeb.AdminInviteController do
  use AtollWeb, :controller
  alias Atoll.Accounts.Invites
  plug AtollWeb.AdminAuth
  action_fallback AtollWeb.XRPCFallback

  def index(conn, params) do
    with {:ok, result} <- Atoll.Accounts.InviteListing.admin(params), do: json(conn, result)
  end

  def create(conn, _) do
    case conn.body_params do
      %{"useCount" => count} = params ->
        if Map.keys(params) -- ["useCount", "forAccount"] == [] do
          with {:ok, result} <- Invites.create(count, params["forAccount"]),
               do: json(conn, %{code: result.code})
        else
          {:error, :invalid_request}
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  def create_many(conn, _) do
    with {:ok, codes} <- Invites.create_many(conn.body_params), do: json(conn, %{codes: codes})
  end

  def disable(conn, _) do
    with {:ok, _} <- Invites.disable_many(conn.body_params), do: send_resp(conn, 200, "")
  end
end
