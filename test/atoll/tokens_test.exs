defmodule Atoll.Accounts.TokensTest do
  use ExUnit.Case, async: true
  alias Atoll.Accounts.Tokens
  @did "did:plc:tokens"
  @opts [
    secret: :binary.copy(<<7>>, 32),
    audience: "did:web:pds.example.test",
    now: 1_800_000_000
  ]

  test "issues distinct scoped tokens and enforces exact expiration boundaries" do
    {:ok, pair} = Tokens.pair(@did, Tokens.random_id(), @opts)
    assert {:ok, access} = Tokens.verify(pair.access_jwt, :access, @opts)
    assert {:ok, refresh} = Tokens.verify(pair.refresh_jwt, :refresh, @opts)
    assert access["sub"] == @did
    assert access["scope"] == "com.atproto.access"
    assert refresh["scope"] == "com.atproto.refresh"
    assert Tokens.digest(refresh["jti"]) == pair.refresh_hash
    assert access["exp"] - access["iat"] == 7200
    assert refresh["exp"] - refresh["iat"] == 90 * 86_400

    assert {:ok, _} =
             Tokens.verify(pair.access_jwt, :access, Keyword.put(@opts, :now, access["exp"] - 1))

    assert Tokens.verify(pair.access_jwt, :access, Keyword.put(@opts, :now, access["exp"])) ==
             {:error, :expired_token}

    assert Tokens.verify(pair.refresh_jwt, :refresh, Keyword.put(@opts, :now, refresh["exp"])) ==
             {:error, :expired_token}

    assert Tokens.verify(pair.access_jwt, :refresh, @opts) == {:error, :invalid_token}
    assert Tokens.verify(pair.refresh_jwt, :access, @opts) == {:error, :invalid_token}
  end

  test "rejects malformed, unsigned, wrongly signed and wrong-audience tokens" do
    {:ok, pair} = Tokens.pair(@did, Tokens.random_id(), @opts)

    assert Tokens.verify(
             pair.access_jwt,
             :access,
             Keyword.put(@opts, :secret, :binary.copy(<<8>>, 32))
           ) == {:error, :invalid_token}

    assert Tokens.verify(
             pair.access_jwt,
             :access,
             Keyword.put(@opts, :audience, "did:web:other.test")
           ) == {:error, :invalid_token}

    for token <- [
          nil,
          %{},
          "",
          "a.b.c",
          pair.access_jwt <> "x",
          String.duplicate("x", 8193),
          "eyJhbGciOiJub25lIiwidHlwIjoiYXQrand0In0.e30."
        ] do
      assert Tokens.verify(token, :access, @opts) == {:error, :invalid_token}
    end
  end

  test "rejects valid signatures with wrong type, scope, times, or identity claims" do
    {:ok, pair} = Tokens.pair(@did, Tokens.random_id(), @opts)
    {:ok, claims} = Tokens.verify(pair.access_jwt, :access, @opts)

    for change <- [
          %{"scope" => "com.atproto.refresh"},
          %{"exp" => "later"},
          %{"iat" => @opts[:now] + 1, "exp" => @opts[:now] + 7201},
          %{"exp" => @opts[:now] + 7201},
          %{"sub" => "invalid"},
          %{"sid" => ""},
          %{"aud" => [@opts[:audience]]}
        ] do
      assert Tokens.verify(sign(Map.merge(claims, change)), :access, @opts) ==
               {:error, :invalid_token}
    end

    assert Tokens.verify(sign(claims, %{"alg" => "HS256", "typ" => "JWT"}), :access, @opts) ==
             {:error, :invalid_token}

    assert Tokens.verify(sign(claims, %{"alg" => "HS384", "typ" => "at+jwt"}), :access, @opts) ==
             {:error, :invalid_token}
  end

  test "requires an explicit strong signing key and service DID" do
    for opts <- [
          Keyword.put(@opts, :secret, nil),
          Keyword.put(@opts, :secret, "short"),
          Keyword.put(@opts, :audience, "invalid")
        ] do
      assert Tokens.pair(@did, Tokens.random_id(), opts) ==
               {:error, :session_configuration_missing}

      assert Tokens.verify("a.b.c", :access, opts) == {:error, :session_configuration_missing}
    end
  end

  defp sign(claims, header \\ %{"alg" => "HS256", "typ" => "at+jwt"}) do
    JOSE.JWK.from_oct(@opts[:secret])
    |> JOSE.JWT.sign(header, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end
end
