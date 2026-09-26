defmodule AtollWeb.AdminAccountController do
  use AtollWeb, :controller
  alias Atoll.Accounts.AdminInfo
  plug AtollWeb.AdminAuth
  action_fallback AtollWeb.XRPCFallback

  def show(conn, params) do
    with {:ok, result} <- AdminInfo.get(params), do: json(conn, result)
  end

  def index(conn, params) do
    with {:ok, result} <- AdminInfo.list(params), do: json(conn, result)
  end
end
