defmodule AtollWeb.IdentityController do
  use AtollWeb, :controller

  def recommended(conn, _params) do
    with {:ok, token} <- AtollWeb.BearerToken.get(conn),
         {:ok, result} <- Atoll.Identity.Recommended.get(token) do
      json(conn, result)
    else
      error -> AtollWeb.XRPCFallback.call(conn, error)
    end
  end

  def hosted_handle(conn, _params) do
    host = String.downcase(conn.host)

    conn =
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("cache-control", "no-store")

    if Atoll.Accounts.Signup.hosted_handle?(host) do
      case Atoll.Repo.get_by(Atoll.Accounts.Profile, handle: host) do
        %{did: did} ->
          if Atoll.Accounts.Signup.pending?(did),
            do: send_resp(conn, 404, "Not found"),
            else: conn |> put_resp_content_type("text/plain") |> send_resp(200, did)

        nil ->
          send_resp(conn, 404, "Not found")
      end
    else
      send_resp(conn, 404, "Not found")
    end
  end

  alias Atoll.Identity.Handle

  def resolve_handle(conn, params) do
    opts = Application.get_env(:atoll, :identity_resolution_options, [])

    case Handle.resolve(params["handle"], opts) do
      {:ok, did} ->
        json(conn, %{did: did})

      {:error, :invalid_handle} ->
        conn |> put_status(400) |> json(%{error: "InvalidRequest", message: "Invalid handle."})

      {:error, _} ->
        conn
        |> put_status(400)
        |> json(%{error: "UnableToResolveHandle", message: "Unable to resolve handle."})
    end
  end
end
