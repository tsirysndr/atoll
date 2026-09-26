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
