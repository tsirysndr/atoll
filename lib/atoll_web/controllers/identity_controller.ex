defmodule AtollWeb.IdentityController do
  use AtollWeb, :controller

  def update_handle(conn, params) do
    opts =
      Application.get_env(:atoll, :identity_resolution_options, [])
      |> Keyword.merge(Application.get_env(:atoll, :plc_submission_options, []))

    with {:ok, token} <- AtollWeb.BearerToken.get(conn),
         {:ok, _} <- Atoll.Identity.HandleChanges.update(token, params, opts) do
      send_resp(conn, 200, "")
    else
      error -> AtollWeb.XRPCFallback.call(conn, error)
    end
  end

  def refresh(conn, params) do
    opts = Application.get_env(:atoll, :identity_resolution_options, [])

    with {:ok, token} <- AtollWeb.BearerToken.get(conn),
         {:ok, result} <- Atoll.Identity.Updates.refresh_authenticated(token, params, opts) do
      json(conn, result)
    else
      {:error, :did_not_found} ->
        conn |> put_status(400) |> json(%{error: "DidNotFound", message: "DID not found."})

      {:error, :handle_not_found} ->
        conn |> put_status(400) |> json(%{error: "HandleNotFound", message: "Handle not found."})

      {:error, reason}
      when reason in [
             :resolution_failed,
             :unsafe_destination,
             :invalid_did_document,
             :invalid_did,
             :unsupported_did_method,
             :did_document_too_large,
             :stale_identity_refresh
           ] ->
        AtollWeb.XRPCFallback.call(conn, {:error, :identity_unavailable})

      error ->
        AtollWeb.XRPCFallback.call(conn, error)
    end
  end

  def resolve_did(conn, params) do
    resolve_result(conn, Atoll.Identity.Resolution.did(params["did"], resolution_options()))
  end

  def resolve_identity(conn, params) do
    resolve_result(
      conn,
      Atoll.Identity.Resolution.identity(params["identifier"], resolution_options())
    )
  end

  defp resolution_options, do: Application.get_env(:atoll, :identity_resolution_options, [])

  defp resolve_result(conn, {:ok, result}), do: json(conn, result)

  defp resolve_result(conn, {:error, :did_not_found}),
    do: conn |> put_status(400) |> json(%{error: "DidNotFound", message: "DID not found."})

  defp resolve_result(conn, {:error, :handle_not_found}),
    do: conn |> put_status(400) |> json(%{error: "HandleNotFound", message: "Handle not found."})

  defp resolve_result(conn, {:error, _}),
    do: AtollWeb.XRPCFallback.call(conn, {:error, :identity_unavailable})

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
