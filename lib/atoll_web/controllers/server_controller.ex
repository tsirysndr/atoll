defmodule AtollWeb.ServerController do
  use AtollWeb, :controller

  def identity(conn, _params) do
    conn = put_resp_header(conn, "access-control-allow-origin", "*")

    case Atoll.Identity.Server.document(String.downcase(conn.host)) do
      {:ok, document} ->
        conn
        |> put_resp_header("cache-control", "public, max-age=300")
        |> put_resp_content_type("application/did+ld+json")
        |> send_resp(200, Jason.encode!(document))

      {:error, :not_found} ->
        conn |> put_resp_header("cache-control", "no-store") |> send_resp(404, "Not found")

      {:error, _} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(503, "Server identity is not configured")
    end
  end

  def describe(conn, _params) do
    config = Application.fetch_env!(:atoll, :pds)

    json(conn, %{
      did: Keyword.fetch!(config, :did),
      availableUserDomains: Keyword.fetch!(config, :available_user_domains),
      blobUploadLimit: Atoll.Blobs.max_size()
    })
  end
end
