defmodule AtollWeb.AdminAccountController do
  use AtollWeb, :controller
  alias Atoll.Accounts.AdminInfo
  plug AtollWeb.AdminAuth
  action_fallback AtollWeb.XRPCFallback

  def update_handle(conn, _) do
    opts =
      Application.get_env(:atoll, :identity_resolution_options, [])
      |> Keyword.merge(Application.get_env(:atoll, :plc_submission_options, []))

    with {:ok, _} <- Atoll.Accounts.AdminHandle.update(conn.body_params, opts),
         do: send_resp(conn, 200, "")
  end

  def search(conn, params) do
    with {:ok, result} <- Atoll.Accounts.AdminSearch.search(params), do: json(conn, result)
  end

  def send_email(conn, _) do
    with {:ok, result} <- Atoll.Accounts.AdminMessage.deliver(conn.body_params),
         do: json(conn, result)
  end

  def delete(conn, _) do
    with {:ok, _} <- Atoll.Accounts.Deletion.admin_delete(conn.body_params),
         do: send_resp(conn, 200, "")
  end

  def update_password(conn, _) do
    with {:ok, _} <- Atoll.Accounts.AdminPassword.update(conn.body_params),
         do: send_resp(conn, 200, "")
  end

  def update_email(conn, _) do
    with {:ok, _} <- Atoll.Accounts.AdminEmail.update(conn.body_params),
         do: send_resp(conn, 200, "")
  end

  def show(conn, params) do
    with {:ok, result} <- AdminInfo.get(params), do: json(conn, result)
  end

  def index(conn, params) do
    with {:ok, result} <- AdminInfo.list(params), do: json(conn, result)
  end
end
