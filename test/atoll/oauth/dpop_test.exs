defmodule Atoll.OAuth.DPoPTest do
  use ExUnit.Case, async: true
  alias Atoll.OAuth.DPoP
  @now 1_800_000_000
  @nonce "server-issued-nonce-for-proof-tests"
  @url "https://pds.example.com/xrpc/com.atproto.repo.getRecord"

  setup do
    key = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, public} = JOSE.JWK.to_public_map(key)
    header = %{"typ" => "dpop+jwt", "alg" => "ES256", "jwk" => public}

    claims = %{
      "jti" => "unique-proof-id",
      "htm" => "GET",
      "htu" => @url,
      "iat" => @now,
      "nonce" => @nonce
    }

    %{key: key, header: header, claims: claims}
  end

  test "verifies ES256, strips only request query and returns the RFC JWK thumbprint", c do
    token = proof(c)
    assert {:ok, verified} = DPoP.verify([token], "GET", @url <> "?repo=alice", opts())
    assert verified.jkt == JOSE.JWK.thumbprint(c.key)
    assert verified.jti == c.claims["jti"]
    assert verified.issued_at == @now
    claims = %{c.claims | "htu" => "HTTPS://PDS.example.com:443"}

    assert {:ok, _} =
             DPoP.verify(
               [proof(%{c | claims: claims})],
               "GET",
               "https://pds.example.com/",
               opts()
             )
  end

  test "resource proofs bind both the access token hash and its key thumbprint", c do
    access = "opaque-access-token"
    ath = :crypto.hash(:sha256, access) |> Base.url_encode64(padding: false)
    token = proof(%{c | claims: Map.put(c.claims, "ath", ath)})
    binding = opts() ++ [access_token: access, jkt: JOSE.JWK.thumbprint(c.key)]
    assert {:ok, _} = DPoP.verify([token], "GET", @url, binding)

    for options <- [
          Keyword.put(binding, :access_token, "other"),
          Keyword.put(binding, :jkt, "other"),
          opts() ++ [access_token: access],
          opts() ++ [jkt: JOSE.JWK.thumbprint(c.key)]
        ] do
      assert {:error, :invalid_dpop_proof} = DPoP.verify([token], "GET", @url, options)
    end

    assert {:error, _} = DPoP.verify([proof(c)], "GET", @url, binding)
  end

  test "rejects nonce, method, target and time mismatches", c do
    for changes <- [
          %{"nonce" => "wrong"},
          %{"nonce" => nil},
          %{"htm" => "POST"},
          %{"htu" => @url <> "/other"},
          %{"htu" => @url <> "?ignored=no"},
          %{"htu" => @url <> "#fragment"},
          %{"htu" => "https://user@pds.example.com/xrpc/com.atproto.repo.getRecord"},
          %{"iat" => @now - 301},
          %{"iat" => @now + 31},
          %{"iat" => @now / 1},
          %{"jti" => ""},
          %{"jti" => String.duplicate("x", 257)}
        ] do
      assert {:error, :invalid_dpop_proof} =
               DPoP.verify(
                 [proof(%{c | claims: Map.merge(c.claims, changes)})],
                 "GET",
                 @url,
                 opts()
               )
    end

    assert {:error, _} = DPoP.verify([proof(c)], "GET", @url, now: @now)

    for time <- [@now - 300, @now + 30] do
      assert {:ok, _} =
               DPoP.verify(
                 [proof(%{c | claims: Map.put(c.claims, "iat", time)})],
                 "GET",
                 @url,
                 opts()
               )
    end
  end

  test "header typing, public-only JWK, algorithm and signature are mandatory", c do
    {_, private} = JOSE.JWK.to_map(c.key)

    for header <- [
          Map.put(c.header, "typ", "JWT"),
          Map.put(c.header, "jwk", private),
          Map.put(c.header, "crit", ["unknown"]),
          Map.put(c.header, "jku", "https://example.com/keys")
        ] do
      assert {:error, _} = DPoP.verify([proof(%{c | header: header})], "GET", @url, opts())
    end

    other = JOSE.JWK.generate_key({:ec, :secp256r1})
    assert {:error, _} = DPoP.verify([proof(%{c | key: other})], "GET", @url, opts())
    [h, p, _] = String.split(proof(c), ".")

    assert {:error, _} =
             DPoP.verify(
               [h <> "." <> p <> "." <> Base.url_encode64(<<0::512>>, padding: false)],
               "GET",
               @url,
               opts()
             )

    hs =
      JOSE.JWT.sign(JOSE.JWK.from_oct("secret"), %{c.header | "alg" => "HS256"}, c.claims)
      |> JOSE.JWS.compact()
      |> elem(1)

    assert {:error, _} = DPoP.verify([hs], "GET", @url, opts())
  end

  test "rejects duplicate JSON members at every level, duplicate headers and oversized proofs",
       c do
    header = Jason.encode!(c.header)
    claims = Jason.encode!(c.claims)
    duplicate_header = String.replace_prefix(header, "{", ~s({"typ":"dpop+jwt",))
    duplicate_claims = String.replace_prefix(claims, "{", ~s({"jti":"another",))
    duplicate_jwk = String.replace(header, ~s("kty":"EC"), ~s("kty":"EC","kty":"EC"))

    for {h, p} <- [
          {duplicate_header, claims},
          {header, duplicate_claims},
          {duplicate_jwk, claims}
        ] do
      token = raw_proof(c.key, h, p)
      assert {:error, _} = DPoP.verify([token], "GET", @url, opts())
    end

    for headers <- [
          [],
          [proof(c), proof(c)],
          [String.duplicate("x", 8193)],
          ["not.jwt"],
          ["a.b.c.d"]
        ] do
      assert {:error, _} = DPoP.verify(headers, "GET", @url, opts())
    end
  end

  test "accepts both valid ECDSA signature forms without changing the replay identity", c do
    original = proof(c)
    [h, p, sig] = String.split(original, ".")
    {:ok, <<r::unsigned-big-256, s::unsigned-big-256>>} = Base.url_decode64(sig, padding: false)
    order = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

    other =
      Base.url_encode64(<<r::unsigned-big-256, order - s::unsigned-big-256>>, padding: false)

    assert {:ok, result} = DPoP.verify([original], "GET", @url, opts())
    assert {:ok, ^result} = DPoP.verify([h <> "." <> p <> "." <> other], "GET", @url, opts())
  end

  defp opts, do: [now: @now, nonce: @nonce]
  defp proof(c), do: JOSE.JWT.sign(c.key, c.header, c.claims) |> JOSE.JWS.compact() |> elem(1)

  defp raw_proof(key, header, claims) do
    h = Base.url_encode64(header, padding: false)
    p = Base.url_encode64(claims, padding: false)
    {_, jwk} = JOSE.JWK.to_map(key)
    {:ok, private} = Base.url_decode64(jwk["d"], padding: false)
    der = :crypto.sign(:ecdsa, :sha256, h <> "." <> p, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)

    h <>
      "." <>
      p <> "." <> Base.url_encode64(<<r::unsigned-big-256, s::unsigned-big-256>>, padding: false)
  end
end
