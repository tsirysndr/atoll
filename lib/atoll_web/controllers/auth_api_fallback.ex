defmodule AtollWeb.AuthApiFallback do
  @moduledoc """
  Error mapping for `social.rocksky.auth.*`.

  This is a separate module because a Phoenix controller already defines
  `call/2` as its own Plug entry point: clauses matching error tuples there
  would swallow the action dispatch. Anything not named here falls through to
  the shared XRPC mapping.
  """
  use AtollWeb, :controller

  def call(conn, {:error, reason})
      when reason in [:invalid_token, :expired_token, :forbidden, :auth_required] do
    error(conn, 401, "AuthenticationRequired", "Authentication is required.")
  end

  def call(conn, {:error, :invalid_credentials}),
    do: error(conn, 401, "InvalidCredentials", "Incorrect password.")

  def call(conn, {:error, :totp_rate_limited}) do
    conn
    |> put_resp_header("retry-after", "300")
    |> error(429, "RateLimited", "Too many attempts; try again later.")
  end

  def call(conn, {:error, :totp_already_enabled}),
    do: error(conn, 400, "AlreadyEnabled", "An authenticator is already enabled.")

  def call(conn, {:error, :totp_not_enrolled}),
    do: error(conn, 400, "NotEnrolled", "No authenticator is enrolled.")

  # A wrong or drifted code is the most common outcome of confirming, so it must
  # read as such rather than as a server failure.
  def call(conn, {:error, :invalid_totp}),
    do: error(conn, 400, "InvalidCode", "That code is not valid.")

  def call(conn, {:error, :totp_required}),
    do: error(conn, 401, "InvalidCode", "A two-factor code is required.")

  def call(conn, {:error, reason})
      when reason in [:totp_store_unavailable, :key_vault_unconfigured, :key_decryption_failed] do
    error(conn, 503, "ServiceUnavailable", "Account security storage is unavailable.")
  end

  def call(conn, {:error, :totp_enrollment_expired}),
    do: error(conn, 400, "EnrollmentExpired", "Enrollment expired; start again.")

  def call(conn, {:error, :passkey_limit}),
    do: error(conn, 400, "TooManyPasskeys", "Remove a passkey before adding another.")

  def call(conn, {:error, :invalid_passkey}),
    do: error(conn, 400, "InvalidPasskey", "That passkey request is not valid.")

  def call(conn, {:error, :passkey_store_unavailable}),
    do: error(conn, 503, "ServiceUnavailable", "Passkey storage is unavailable.")

  def call(conn, {:error, :passkeys_disabled}),
    do: error(conn, 501, "NotSupported", "Passkeys are not enabled on this server.")

  # Anything named above is answered precisely. Anything else is still an error
  # tuple, so it must not reach a mapping that raises on an unknown atom: a new
  # error in the factor layer would otherwise surface as a crash.
  def call(conn, {:error, reason} = other) when is_atom(reason) do
    try do
      AtollWeb.XRPCFallback.call(conn, other)
    rescue
      FunctionClauseError ->
        require Logger
        Logger.error("unmapped social.rocksky.auth error: #{inspect(reason)}")
        error(conn, 400, "InvalidRequest", "That request could not be completed.")
    end
  end

  def call(conn, other), do: AtollWeb.XRPCFallback.call(conn, other)

  defp error(conn, status, name, message) do
    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> json(%{error: name, message: message})
  end
end
