defmodule AtollWeb.AdminSubjectController do
  use AtollWeb, :controller
  alias Atoll.Accounts.SubjectStatus
  plug AtollWeb.AdminAuth
  action_fallback AtollWeb.XRPCFallback

  def show(conn, params) do
    with {:ok, result} <- SubjectStatus.get(params), do: json(conn, result)
  end

  def update(conn, _) do
    with {:ok, result} <- SubjectStatus.update(conn.body_params), do: json(conn, result)
  end
end
