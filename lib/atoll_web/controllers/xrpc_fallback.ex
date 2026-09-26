defmodule AtollWeb.XRPCFallback do
  use AtollWeb, :controller

  def call(conn, {:error, reason}) when reason in [:auth_required, :invalid_credentials],
    do: error(conn, 401, "AuthRequired", "Authentication required or credentials incorrect.")

  def call(conn, {:error, :invalid_token}),
    do: error(conn, 401, "InvalidToken", "Invalid session token.")

  def call(conn, {:error, :expired_token}),
    do: error(conn, 401, "ExpiredToken", "Session token has expired.")

  def call(conn, {:error, :session_configuration_missing}),
    do: error(conn, 503, "ServiceUnavailable", "Session signing is not configured.")

  def call(conn, {:error, :invalid_request}) do
    error(conn, 400, "InvalidRequest", "Invalid or unsupported query parameters.")
  end

  def call(conn, {:error, {:repo_inactive, status}}) do
    code =
      case status do
        :deactivated -> "RepoDeactivated"
        :takendown -> "RepoTakendown"
        :suspended -> "RepoSuspended"
      end

    error(conn, 400, code, "Repository is not active.")
  end

  def call(conn, {:error, :record_not_found}),
    do: error(conn, 400, "RecordNotFound", "Record not found.")

  def call(conn, {:error, :blob_not_found}),
    do: error(conn, 400, "BlobNotFound", "Blob is not available in the current repository.")

  def call(conn, {:error, :unverified_handle}),
    do: error(conn, 400, "InvalidRequest", "Unable to verify repository handle.")

  def call(conn, {:error, :identity_unavailable}),
    do: error(conn, 400, "InvalidRequest", "Unable to resolve repository identity.")

  def call(conn, {:error, :block_not_found}),
    do: error(conn, 400, "BlockNotFound", "Block not found in the current repository.")

  def call(conn, {:error, :not_found}),
    do: error(conn, 400, "RepoNotFound", "Repository not found.")

  def call(conn, {:error, :car_too_large}),
    do: error(conn, 413, "RepoTooLarge", "Repository exceeds the in-memory export limit.")

  def call(conn, {:error, _}),
    do: error(conn, 500, "InternalServerError", "Unable to read repository data.")

  defp error(conn, status, code, message),
    do: conn |> put_status(status) |> json(%{error: code, message: message})
end
