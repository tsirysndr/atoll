defmodule AtollWeb.XRPCFallback do
  use AtollWeb, :controller

  def call(conn, {:error, :subject_not_found}),
    do: error(conn, 400, "NotFound", "Subject not found.")

  def call(conn, {:error, :unsupported_moderation_subject}),
    do:
      error(conn, 400, "InvalidRequest", "Expected a local repository, record, or blob subject.")

  def call(conn, {:error, :invalid_invite_allocation}),
    do: error(conn, 503, "ServiceUnavailable", "Invite allocation is misconfigured.")

  def call(conn, {:error, :invite_listing_too_large}),
    do:
      error(
        conn,
        400,
        "InvalidRequest",
        "Invite history is too large; use administrator pagination."
      )

  def call(conn, {:error, :admin_busy}),
    do: error(conn, 503, "ServiceUnavailable", "Administrative service is busy; retry later.")

  def call(conn, {:error, :invalid_invite_code}),
    do: error(conn, 400, "InvalidInviteCode", "A valid, available invite code is required.")

  def call(conn, {:error, :signup_disabled}),
    do: error(conn, 403, "Forbidden", "Fresh signup is disabled.")

  def call(conn, {:error, :unsupported_domain}),
    do: error(conn, 400, "UnsupportedDomain", "Choose a handle under an available server domain.")

  def call(conn, {:error, :signup_pending}),
    do: error(conn, 503, "ServiceUnavailable", "Retry account creation to complete registration.")

  def call(conn, {:error, reason})
      when reason in [
             :plc_unavailable,
             :plc_rejected,
             :plc_conflict,
             :invalid_plc_response,
             :invalid_plc_operation,
             :invalid_plc_directory
           ],
      do: error(conn, 503, "ServiceUnavailable", "Identity registration is unavailable.")

  def call(conn, {:error, :repository_quota_exceeded}),
    do: error(conn, 400, "RepoQuotaExceeded", "Repository storage quota exceeded.")

  def call(conn, {:error, :invalid_repository_quota}),
    do: error(conn, 503, "ServiceUnavailable", "Repository storage quota is misconfigured.")

  def call(conn, {:error, :auth_factor_required}),
    do: error(conn, 400, "AuthFactorTokenRequired", "Check your email for a login code.")

  def call(conn, {:error, :invalid_auth_factor}),
    do: error(conn, 401, "AuthRequired", "Invalid or expired authentication factor.")

  def call(conn, {:error, :email_factor_unconfirmed}),
    do:
      error(
        conn,
        400,
        "InvalidRequest",
        "Confirm the current email before enabling an authentication factor."
      )

  def call(conn, {:error, :app_password_exists}),
    do: error(conn, 400, "InvalidRequest", "App password name is already in use.")

  def call(conn, {:error, :app_password_limit}),
    do: error(conn, 400, "InvalidRequest", "Account app password limit reached.")

  def call(conn, {:error, :email_token_required}),
    do: error(conn, 400, "TokenRequired", "A token from the current email address is required.")

  def call(conn, {:error, :invalid_email}),
    do: error(conn, 400, "InvalidEmail", "Email is invalid or does not match the account.")

  def call(conn, {:error, :invalid_email_token}),
    do: error(conn, 400, "InvalidToken", "Invalid email token.")

  def call(conn, {:error, :expired_email_token}),
    do: error(conn, 400, "ExpiredToken", "Email token has expired.")

  def call(conn, {:error, :account_not_found}),
    do: error(conn, 400, "AccountNotFound", "Account profile is unavailable.")

  def call(conn, {:error, :email_rate_limited}),
    do: error(conn, 429, "RateLimitExceeded", "Wait one minute before requesting another email.")

  def call(conn, {:error, reason})
      when reason in [
             :email_not_configured,
             :email_delivery_unavailable,
             :email_delivery_rejected
           ],
      do: error(conn, 503, "ServiceUnavailable", "Email delivery is unavailable.")

  def call(conn, {:error, reason})
      when reason in [:invalid_service_token, :service_token_replayed],
      do: error(conn, 401, "InvalidToken", "Invalid or already used service token.")

  def call(conn, {:error, :invalid_password}),
    do: error(conn, 400, "InvalidPassword", "Password must be valid UTF-8 and 8–1024 bytes.")

  def call(conn, {:error, :account_exists}),
    do: error(conn, 400, "InvalidRequest", "Account already exists.")

  def call(conn, {:error, :handle_not_available}),
    do: error(conn, 400, "HandleNotAvailable", "Handle is already in use.")

  def call(conn, {:error, :email_not_available}),
    do: error(conn, 400, "InvalidRequest", "Email is already in use.")

  def call(conn, {:error, :invalid_did_document}),
    do:
      error(conn, 400, "IncompatibleDidDoc", "DID document is incompatible with account import.")

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

  def call(conn, {:error, :invalid_record_schema}),
    do: error(conn, 400, "InvalidRequest", "Record does not match its Lexicon schema.")

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

  def call(conn, {:error, :blob_taken_down}),
    do: error(conn, 400, "BlobTakendown", "Blob is unavailable due to a takedown.")

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
