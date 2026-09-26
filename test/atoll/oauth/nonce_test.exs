defmodule Atoll.OAuth.NonceTest do
  use ExUnit.Case, async: true
  alias Atoll.OAuth.Nonce
  @now 1_800_000_000

  test "nonces are unpredictable, authenticated, issuer/role bound and time limited" do
    opts = [secret: :crypto.strong_rand_bytes(32), issuer: "https://pds.example.com", now: @now]
    {:ok, first} = Nonce.issue(:authorization, opts)
    {:ok, second} = Nonce.issue(:authorization, opts)
    refute first == second
    assert {:ok, %{expires_at: expires}} = Nonce.verify(first, :authorization, opts)
    assert expires == @now + 300
    assert {:ok, _} = Nonce.verify(first, :authorization, Keyword.put(opts, :now, @now + 299))

    for changed <- [
          Keyword.put(opts, :now, @now + 300),
          Keyword.put(opts, :now, @now - 6),
          Keyword.put(opts, :issuer, "https://other.example.com"),
          Keyword.put(opts, :secret, :crypto.strong_rand_bytes(32))
        ] do
      assert {:error, :use_dpop_nonce} = Nonce.verify(first, :authorization, changed)
    end

    assert {:error, :use_dpop_nonce} = Nonce.verify(first, :resource, opts)
    {:ok, bytes} = Base.url_decode64(first, padding: false)
    <<initial, rest::binary>> = bytes
    tampered = Base.url_encode64(<<Bitwise.bxor(initial, 1), rest::binary>>, padding: false)
    assert {:error, :use_dpop_nonce} = Nonce.verify(tampered, :authorization, opts)
    assert {:error, :use_dpop_nonce} = Nonce.verify(first <> "=", :authorization, opts)
  end

  test "configuration is optional until used and malformed secrets are not exposed" do
    assert Nonce.secret_from_env!(nil) == nil
    secret = :crypto.strong_rand_bytes(32)
    assert Nonce.secret_from_env!(Base.encode64(secret)) == secret
    assert {:error, :oauth_nonce_unconfigured} = Nonce.issue(:resource, secret: nil)
    error = assert_raise ArgumentError, fn -> Nonce.secret_from_env!("private-invalid-value") end
    refute Exception.message(error) =~ "private-invalid-value"
  end
end
