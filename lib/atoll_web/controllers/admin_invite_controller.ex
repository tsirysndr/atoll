defmodule AtollWeb.AdminInviteController do
  use AtollWeb, :controller
  alias Atoll.Accounts.AdminInvites
  plug AtollWeb.AdminAuth
  action_fallback AtollWeb.XRPCFallback

  def disable_account(conn, _) do
    with {:ok, _} <- Atoll.Accounts.InviteControl.set(conn.body_params, true),
         do: send_resp(conn, 200, "")
  end

  def enable_account(conn, _) do
    with {:ok, _} <- Atoll.Accounts.InviteControl.set(conn.body_params, false),
         do: send_resp(conn, 200, "")
  end

  def index(conn, params) do
    with {:ok, result} <- Atoll.Accounts.InviteListing.admin(params), do: json(conn, result)
  end

  def create(conn, _) do
    with {:ok, result} <- AdminInvites.create(conn.body_params),
         do: json(conn, %{code: result.code})
  end

  def create_many(conn, _) do
    with {:ok, codes} <- AdminInvites.create_many(conn.body_params),
         do: json(conn, %{codes: codes})
  end

  def disable(conn, _) do
    with {:ok, _} <- AdminInvites.disable(conn.body_params), do: send_resp(conn, 200, "")
  end
end
