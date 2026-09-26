defmodule AtollWeb.RepoImportController do
  use AtollWeb, :controller
  action_fallback AtollWeb.XRPCFallback

  def create(%{private: %{atoll_repo_import: upload}} = conn, _params) do
    with {:ok, _} <-
           Atoll.Repositories.import_authenticated(upload.token, upload.bytes, upload.head),
         do: send_resp(conn, 200, "")
  end

  def create(_, _), do: {:error, :auth_required}
end
