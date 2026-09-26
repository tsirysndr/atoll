defmodule Atoll.MultikeyTest do
  use ExUnit.Case, async: true
  alias Atoll.{Multikey, SigningKey}

  test "accepts the protocol specification's published examples" do
    # https://atproto.com/specs/cryptography#public-key-encoding
    for {curve, text} <- [
          {:p256, "zDnaembgSGUhZULN2Caob4HLJPaxBh92N7rtH21TErzqf8HQo"},
          {:k256, "zQ3shqwJEJyMBsBXCWyCBpUBMqxcon9oHB7mCvx4sSpMdLJwc"}
        ] do
      assert {:ok, %{curve: ^curve, public: public}} = Multikey.decode(text)
      assert byte_size(public) == 33
      assert Multikey.encode(curve, public) == {:ok, text}
      assert Multikey.to_did_key(curve, public) == {:ok, "did:key:" <> text}
      assert Multikey.from_did_key("did:key:" <> text) == {:ok, %{curve: curve, public: public}}
    end
  end

  test "decoded keys verify signatures on both curves" do
    for curve <- [:p256, :k256] do
      key = SigningKey.generate(curve)
      {:ok, text} = Multikey.encode(curve, key.public)
      {:ok, decoded} = Multikey.decode(text)
      {:ok, signature} = SigningKey.sign(key, "example")
      assert SigningKey.verify(decoded.curve, decoded.public, "example", signature)
    end
  end

  test "rejects noncanonical base58, unsupported formats and invalid curve points" do
    for value <- [
          nil,
          "",
          "z",
          "z0OIl",
          "z" <> String.duplicate("1", 100),
          "z1DnaembgSGUhZULN2Caob4HLJPaxBh92N7rtH21TErzqf8HQo",
          "bDnaembgSGUhZULN2Caob4HLJPaxBh92N7rtH21TErzqf8HQo"
        ] do
      assert Multikey.decode(value) == {:error, :invalid_multikey}
    end

    for curve <- [:p256, :k256] do
      assert Multikey.encode(curve, <<2>> <> :binary.copy(<<255>>, 32)) ==
               {:error, :invalid_multikey}

      assert Multikey.encode(curve, <<4, 1::256>>) == {:error, :invalid_multikey}
    end

    assert Multikey.encode(:ed25519, <<2, 1::256>>) == {:error, :invalid_multikey}
    assert Multikey.from_did_key("did:web:example.com") == {:error, :invalid_multikey}
  end
end
