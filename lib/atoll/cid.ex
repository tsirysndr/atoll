defmodule Atoll.CID do
  @moduledoc """
  Constructs CIDv1 identifiers using SHA-256.
  """

  alias Atoll.Varint

  @type codec :: :dag_cbor | :raw

  @doc """
  Returns a binary CID for already-encoded content.

  Does not encode or validate the content itself.
  """
  @spec create(binary(), codec()) :: binary()
  def create(content, codec)
      when is_binary(content) and codec in [:dag_cbor, :raw] do
    digest = :crypto.hash(:sha256, content)

    Varint.encode(1) <>
      Varint.encode(codec_code(codec)) <>
      Varint.encode(0x12) <>
      Varint.encode(byte_size(digest)) <>
      digest
  end

  @doc """
  Formats a binary CID as lowercase, unpadded base32 with a multibase prefix.
  """
  @spec to_base32(binary()) :: String.t()
  def to_base32(cid) when is_binary(cid) do
    "b" <> Base.encode32(cid, case: :lower, padding: false)
  end

  defp codec_code(:dag_cbor), do: 0x71
  defp codec_code(:raw), do: 0x55
end
