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

  def call(conn, {:error, :totp_enrollment_expired}),
    do: error(conn, 400, "EnrollmentExpired", "Enrollment expired; start again.")

  def call(conn, {:error, :passkey_limit}),
    do: error(conn, 400, "TooManyPasskeys", "Remove a passkey before adding another.")

  def call(conn, {:error, :invalid_passkey}),
    do: error(conn, 400, "InvalidPasskey", "That passkey request is not valid.")

  def call(conn, {:error, :passkeys_disabled}),
    do: error(conn, 501, "NotSupported", "Passkeys are not enabled on this server.")

  def call(conn, other), do: AtollWeb.XRPCFallback.call(conn, other)

  defp error(conn, status, name, message) do
    conn
    |> put_status(status)
    |> put_resp_header("cache-control", "no-store")
    |> json(%{error: name, message: message})
  end
end
