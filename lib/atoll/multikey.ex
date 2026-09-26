defmodule Atoll.Multikey do
  @moduledoc "ATProto compressed P-256 and secp256k1 public keys in base58btc multikey and did:key form."
  @alphabet "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @digits @alphabet |> :binary.bin_to_list() |> Enum.with_index() |> Map.new()

  def encode(curve, public) do
    if valid_point?(curve, public) do
      prefix = if curve == :p256, do: <<0x80, 0x24>>, else: <<0xE7, 1>>
      {:ok, "z" <> base58(:binary.decode_unsigned(prefix <> public), "")}
    else
      {:error, :invalid_multikey}
    end
  end

  def decode("z" <> text) when byte_size(text) in 1..49 do
    with {:ok, number} <- unbase58(text),
         {:ok, curve, public} <- split(:binary.encode_unsigned(number)),
         {:ok, canonical} <- encode(curve, public),
         true <- canonical == "z" <> text do
      {:ok, %{curve: curve, public: public}}
    else
      _ -> {:error, :invalid_multikey}
    end
  end

  def decode(_), do: {:error, :invalid_multikey}

  def to_did_key(curve, public) do
    with {:ok, encoded} <- encode(curve, public), do: {:ok, "did:key:" <> encoded}
  end

  def from_did_key("did:key:" <> encoded), do: decode(encoded)
  def from_did_key(_), do: {:error, :invalid_multikey}

  defp split(<<0x80, 0x24, public::binary-size(33)>>), do: {:ok, :p256, public}
  defp split(<<0xE7, 1, public::binary-size(33)>>), do: {:ok, :k256, public}
  defp split(_), do: {:error, :invalid_multikey}

  defp valid_point?(curve, <<prefix, _::binary-size(32)>> = public)
       when curve in [:p256, :k256] and prefix in [2, 3] do
    # OpenSSL validates and decompresses the public point. Scalar one is public;
    # no private signing material is involved in this point-validation operation.
    otp_curve = if curve == :p256, do: :secp256r1, else: :secp256k1
    is_binary(:crypto.compute_key(:ecdh, public, <<1::256>>, otp_curve))
  catch
    :error, _ -> false
  end

  defp valid_point?(_, _), do: false

  defp base58(0, acc), do: acc
  defp base58(n, acc), do: base58(div(n, 58), <<:binary.at(@alphabet, rem(n, 58))>> <> acc)

  defp unbase58(text) do
    Enum.reduce_while(:binary.bin_to_list(text), {:ok, 0}, fn char, {:ok, acc} ->
      case Map.fetch(@digits, char) do
        {:ok, digit} -> {:cont, {:ok, acc * 58 + digit}}
        :error -> {:halt, :error}
      end
    end)
  end
end
