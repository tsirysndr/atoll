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

  @doc """
  Parses a complete binary CID in the supported ATProto formats.
  """
  @spec decode(binary()) ::
          {:ok, %{codec: codec(), digest: binary()}}
          | {:error, :invalid_cid}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, 1, rest} <- Varint.decode(bytes),
         {:ok, code, rest} when code in [0x71, 0x55] <- Varint.decode(rest),
         {:ok, 0x12, rest} <- Varint.decode(rest),
         {:ok, 32, digest} <- Varint.decode(rest),
         true <- byte_size(digest) == 32 do
      codec = if code == 0x71, do: :dag_cbor, else: :raw

      {:ok, %{codec: codec, digest: digest}}
    else
      _ -> {:error, :invalid_cid}
    end
  end

  @doc """
  Parses a canonical base32 string into a validated binary CID.
  """
  @spec from_base32(term()) :: {:ok, binary()} | {:error, :invalid_cid}
  def from_base32("b" <> encoded = text) when byte_size(encoded) == 58 do
    with {:ok, cid} <- Base.decode32(encoded, case: :lower, padding: false),
         {:ok, _fields} <- decode(cid),
         true <- to_base32(cid) == text do
      {:ok, cid}
    else
      _ -> {:error, :invalid_cid}
    end
  end

  def from_base32(_value) do
    {:error, :invalid_cid}
  end

  @doc """
  Checks that content matches a supported binary CID's digest.

  Does not validate the content's codec-specific encoding.
  """
  @spec verify(binary(), binary()) ::
          :ok | {:error, :invalid_cid | :content_mismatch}
  def verify(cid, content) when is_binary(cid) and is_binary(content) do
    with {:ok, %{digest: digest}} <- decode(cid) do
      if :crypto.hash(:sha256, content) == digest do
        :ok
      else
        {:error, :content_mismatch}
      end
    end
  end

  defp codec_code(:dag_cbor), do: 0x71
  defp codec_code(:raw), do: 0x55
end
