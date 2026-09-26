defmodule Atoll.SigningKey do
  @moduledoc """
  ECDSA keys and compact, low-S SHA-256 signatures for ATProto.

  Cryptographic operations and nonce generation are delegated to OTP/OpenSSL.
  Private keys are in-memory only; persistence and rotation are separate concerns.
  """
  @derive {Inspect, only: [:curve, :public]}
  @enforce_keys [:curve, :public, :private]
  defstruct [:curve, :public, :private]

  @orders %{
    p256: 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551,
    k256: 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  }

  def generate(curve \\ :k256) when curve in [:p256, :k256] do
    {public, private} = :crypto.generate_key(:ecdh, otp_curve(curve))
    %__MODULE__{curve: curve, public: compress(public), private: private}
  end

  def from_private(curve, <<value::unsigned-big-256>> = private) when curve in [:p256, :k256] do
    if value > 0 and value < Map.fetch!(@orders, curve) do
      {public, _} = :crypto.generate_key(:ecdh, otp_curve(curve), private)
      {:ok, %__MODULE__{curve: curve, public: compress(public), private: private}}
    else
      {:error, :invalid_key}
    end
  end

  def from_private(_, _), do: {:error, :invalid_key}

  @doc "Signs message bytes (hashes once with SHA-256), returning a 64-byte r || s signature."
  def sign(%__MODULE__{curve: curve, private: private}, bytes) when is_binary(bytes) do
    with {:ok, _key} <- from_private(curve, private) do
      der = :crypto.sign(:ecdsa, :sha256, bytes, [private, otp_curve(curve)])
      {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
      s = min(s, Map.fetch!(@orders, curve) - s)
      {:ok, <<r::unsigned-big-256, s::unsigned-big-256>>}
    end
  end

  def sign(_, _), do: {:error, :invalid_key}

  @doc "Verifies compact signatures using a compressed or uncompressed SEC1 public key."
  def verify(curve, public, bytes, <<r::unsigned-big-256, s::unsigned-big-256>>)
      when curve in [:p256, :k256] and is_binary(public) and is_binary(bytes) do
    order = Map.fetch!(@orders, curve)

    if valid_public_format?(public) and r > 0 and r < order and s > 0 and s <= div(order, 2) do
      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
      :crypto.verify(:ecdsa, :sha256, bytes, der, [public, otp_curve(curve)])
    else
      false
    end
  catch
    :error, _ -> false
  end

  def verify(_, _, _, _), do: false

  defp compress(<<4, x::binary-size(32), y::unsigned-big-256>>), do: <<2 + rem(y, 2)>> <> x
  defp valid_public_format?(<<prefix, _::binary-size(32)>>) when prefix in [2, 3], do: true
  defp valid_public_format?(<<4, _::binary-size(64)>>), do: true
  defp valid_public_format?(_), do: false
  defp otp_curve(:p256), do: :secp256r1
  defp otp_curve(:k256), do: :secp256k1
end
