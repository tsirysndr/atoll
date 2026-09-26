defmodule AtollWeb.XRPCFallback do
  use AtollWeb, :controller

  def call(conn, {:error, reason}) when reason in [:invalid_snapshot, :stale_revision],
    do: error(conn, 400, "InvalidRequest", "Invalid or stale repository snapshot.")

  def call(conn, {:error, :request_timeout}),
    do: error(conn, 408, "RequestTimeout", "Request body timed out.")

  def call(conn, {:error, :bad_expiration}),
    do:
      error(
        conn,
        400,
        "BadExpiration",
        "Service token expiration is outside the permitted interval."
      )

  def call(conn, {:error, :import_rate_limited}),
    do: error(conn, 429, "RateLimitExceeded", "Too many repository imports.")

  def call(conn, {:error, :forbidden}),
    do: error(conn, 403, "Forbidden", "Token does not authorize this repository.")

  def call(conn, {:error, :invalid_swap}),
    do: error(conn, 400, "InvalidSwap", "Repository or record version does not match.")

  def call(conn, {:error, :validation_unavailable}),
    do: error(conn, 400, "InvalidRequest", "Required Lexicon validation is not available.")

  def call(conn, {:error, reason})
      when reason in [:invalid_record, :record_exists, :invalid_blob_metadata, :duplicate_path],
      do: error(conn, 400, "InvalidRequest", "Invalid record data or record already exists.")

  def call(conn, {:error, reason}) when reason in [:key_vault_unconfigured, :key_not_found],
    do: error(conn, 503, "ServiceUnavailable", "Repository signing key is unavailable.")

  def call(conn, {:error, :record_request_too_large}),
    do: error(conn, 413, "InvalidRequest", "Record request body exceeds 2 MiB.")

  def call(conn, {:error, :record_rate_limited}),
    do: error(conn, 429, "RateLimitExceeded", "Too many record writes.")

  def call(conn, {:error, :blob_too_large}),
    do: error(conn, 413, "BlobTooLarge", "Blob exceeds the 5 MiB limit.")

  def call(conn, {:error, :blob_quota_exceeded}),
    do: error(conn, 400, "BlobQuotaExceeded", "Account blob quota exceeded.")

  def call(conn, {:error, reason}) when reason in [:invalid_mime_type, :content_length_mismatch],
    do: error(conn, 400, "InvalidRequest", "Invalid blob media type or content length.")

  def call(conn, {:error, :blob_storage_unavailable}),
    do: error(conn, 503, "ServiceUnavailable", "Blob storage is unavailable.")

  def call(conn, {:error, :upload_timeout}),
    do: error(conn, 408, "RequestTimeout", "Blob upload timed out.")

  def call(conn, {:error, :upload_rate_limited}),
    do: error(conn, 429, "RateLimitExceeded", "Too many blob uploads.")

  def call(conn, {:error, reason}) when reason in [:auth_required, :invalid_credentials],
    do: error(conn, 401, "AuthRequired", "Authentication required or credentials incorrect.")

  def call(conn, {:error, :invalid_token}),
    do: error(conn, 401, "InvalidToken", "Invalid session token.")

  def call(conn, {:error, :session_limit_exceeded}),
    do:
      error(
        conn,
        429,
        "RateLimitExceeded",
        "Account session limit reached; revoke a session before logging in again."
      )

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
