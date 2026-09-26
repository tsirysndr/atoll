defmodule Atoll.Accounts.TOTP do
  @moduledoc """
  RFC 6238 authenticator primitives: SHA-1, six digits and 30-second steps.

  Not an authentication boundary. Callers must decrypt an account's enrolled
  secret, rate-limit attempts, and atomically persist the returned step under
  an account/factor row lock before granting access. A successful verification
  without that transaction does not provide one-time use or replay protection.
  Secrets and provisioning URIs must never be logged or sent to third parties.
  """
  import Bitwise
  @period 30
  @max_step 18_446_744_073_709_551_615
  @max_time @max_step * @period + @period - 1

  @doc "Generate a fresh 160-bit secret; retain it only in encrypted account storage."
  def generate_secret, do: :crypto.strong_rand_bytes(20)

  @doc "Generate a six-digit code at a trusted Unix timestamp, including leading zeroes."
  def code(secret, unix_seconds)
      when is_binary(secret) and byte_size(secret) in 20..64 and
             is_integer(unix_seconds) and unix_seconds >= 0 and unix_seconds <= @max_time do
    {:ok, at_step(secret, div(unix_seconds, @period))}
  end

  def code(_, _), do: {:error, :invalid_totp_parameters}

  @doc """
  Verify an ASCII six-digit code in the current, previous or next step.
  `last_used_step` is persisted trusted state (-1 before first use). Matching
  all steps before selecting the highest prevents an adjacent-step collision
  from allowing the same submitted code twice within this window.
  """
  def verify(secret, value, unix_seconds, last_used_step)
      when is_binary(secret) and byte_size(secret) in 20..64 and is_binary(value) and
             byte_size(value) == 6 and is_integer(unix_seconds) and unix_seconds >= 0 and
             unix_seconds <= @max_time and is_integer(last_used_step) and
             last_used_step >= -1 and last_used_step <= @max_step do
    if Regex.match?(~r/\A[0-9]{6}\z/, value) do
      current = div(unix_seconds, @period)

      matched =
        Enum.reduce(max(0, current - 1)..min(@max_step, current + 1), -1, fn step, found ->
          # Always evaluate every candidate; do not short-circuit on the first match.
          if Plug.Crypto.secure_compare(at_step(secret, step), value),
            do: max(step, found),
            else: found
        end)

      if matched > last_used_step, do: {:ok, matched}, else: {:error, :invalid_totp}
    else
      {:error, :invalid_totp}
    end
  end

  def verify(_, _, _, _), do: {:error, :invalid_totp}

  @doc "Build a Google Authenticator-compatible provisioning URI from trusted display labels."
  def provisioning_uri(secret, account, issuer \\ "Atoll") do
    if is_binary(secret) and byte_size(secret) in 20..64 and label?(account) and label?(issuer) do
      label =
        URI.encode(issuer, &URI.char_unreserved?/1) <>
          ":" <> URI.encode(account, &URI.char_unreserved?/1)

      query =
        URI.encode_query(%{
          "secret" => Base.encode32(secret, padding: false),
          "issuer" => issuer,
          "algorithm" => "SHA1",
          "digits" => "6",
          "period" => "30"
        })

      {:ok, "otpauth://totp/" <> label <> "?" <> query}
    else
      {:error, :invalid_totp_parameters}
    end
  end

  defp label?(label) when is_binary(label) and byte_size(label) in 1..256,
    do: String.valid?(label) and not Regex.match?(~r/[:\x00-\x1f\x7f]/, label)

  defp label?(_), do: false

  defp at_step(secret, step) do
    digest = :crypto.mac(:hmac, :sha, secret, <<step::unsigned-big-64>>)
    offset = :binary.last(digest) &&& 15
    <<number::unsigned-big-32>> = binary_part(digest, offset, 4)
    rem(number &&& 0x7FFF_FFFF, 1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end
end
