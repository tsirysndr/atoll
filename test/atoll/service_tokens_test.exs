defmodule Atoll.Accounts.ServiceTokensTest do
  use Atoll.DataCase, async: true
  alias Atoll.{Multikey, Repo, SigningKey}
  alias Atoll.Accounts.{ServiceTokens, ServiceTokenUse}
  @did "did:web:issuer.example.com"
  @aud "did:web:pds.example.com#atproto_pds"
  @method "com.atproto.server.createAccount"

  test "accepts account signatures on both curves without requiring a PDS service and rejects replays" do
    for curve <- [:p256, :k256] do
      {key, claims, opts} = fixture(curve)
      token = token(key, claims)
      assert {:ok, ^claims} = ServiceTokens.authenticate(token, @aud, @method, opts)

      assert {:error, :service_token_replayed} =
               ServiceTokens.authenticate(token, @aud, @method, opts)

      # A newly signed token with the same issuer/nonce is still the same use.
      assert {:error, :service_token_replayed} =
               ServiceTokens.authenticate(token(key, claims), @aud, @method, opts)
    end

    assert Repo.aggregate(ServiceTokenUse, :count) == 2
  end

  test "rejects invalid claims, expiration, headers, and signatures without consuming anything" do
    {key, claims, opts} = fixture(:k256)

    for changed <- [
          Map.put(claims, "aud", "did:web:other.example.com"),
          Map.put(claims, "aud", "did:web:pds.example.com"),
          Map.put(claims, "lxm", "com.atproto.repo.importRepo"),
          Map.delete(claims, "lxm"),
          Map.delete(claims, "jti"),
          Map.put(claims, "jti", ""),
          Map.put(claims, "jti", String.duplicate("a", 257)),
          Map.put(claims, "iat", claims["iat"] + 31),
          Map.put(claims, "exp", claims["iat"] + 3601),
          Map.put(claims, "iss", @did <> "#other")
        ] do
      assert {:error, :invalid_service_token} =
               ServiceTokens.authenticate(token(key, changed), @aud, @method, opts)
    end

    expired = %{claims | "iat" => claims["iat"] - 60, "exp" => claims["iat"]}

    assert {:error, :expired_token} =
             ServiceTokens.authenticate(token(key, expired), @aud, @method, opts)

    for header <- [
          %{alg: "none", typ: "JWT"},
          %{alg: "HS256", typ: "JWT"},
          %{alg: "ES256", typ: "JWT"},
          %{alg: "ES256K", typ: "at+jwt"},
          %{alg: "ES256K", typ: "JWT", kid: "#other"},
          %{alg: "ES256K", typ: "JWT", crit: ["b64"]}
        ] do
      assert {:error, :invalid_service_token} =
               ServiceTokens.authenticate(token(key, claims, header), @aud, @method, opts)
    end

    assert {:error, :invalid_service_token} =
             ServiceTokens.authenticate(token(SigningKey.generate(), claims), @aud, @method, opts)

    refute Repo.exists?(ServiceTokenUse)
  end

  test "service authorization refreshes a cached signing key before accepting a token" do
    cache = start_supervised!({Atoll.Identity.Cache, []})
    {old_key, claims, old_opts} = fixture(:k256)
    old_opts = Keyword.put(old_opts, :cache, cache)
    assert {:ok, old_doc} = Atoll.Identity.Resolver.resolve_document(@did, old_opts)
    {new_key, _, new_opts} = fixture(:k256)
    new_opts = Keyword.merge(new_opts, cache: cache, force_refresh: false)
    # A routine lookup still sees the old key, proving the cache is populated.
    assert {:ok, ^old_doc} = Atoll.Identity.Resolver.resolve_document(@did, new_opts)

    assert {:error, :invalid_service_token} =
             ServiceTokens.authenticate(token(old_key, claims), @aud, @method, new_opts)

    refute Repo.exists?(ServiceTokenUse)

    assert {:ok, ^claims} =
             ServiceTokens.authenticate(token(new_key, claims), @aud, @method, new_opts)
  end

  test "rejects malformed encoding and duplicate JSON claims before resolution" do
    {key, claims, opts} = fixture(:k256)

    opts =
      Keyword.put(opts, :lookup, fn _ -> flunk("invalid JWT must not trigger resolution") end)

    header = Jason.encode!(%{alg: "ES256K", typ: "JWT"})
    duplicate = "{\"iss\":\"#{@did}\"," <> String.trim_leading(Jason.encode!(claims), "{")

    for value <- [
          "bad",
          "a.b.c",
          String.duplicate("a", 8193),
          token_json(key, header, duplicate),
          token_json(
            key,
            "{\"alg\":\"none\",\"alg\":\"ES256K\",\"typ\":\"JWT\"}",
            Jason.encode!(claims)
          )
        ] do
      assert {:error, :invalid_service_token} =
               ServiceTokens.authenticate(value, @aud, @method, opts)
    end
  end

  test "rejects ambiguous or wrong-controller DID keys" do
    {key, claims, opts} = fixture(:k256)
    {:ok, multikey} = Multikey.encode(key.curve, key.public)

    method = %{
      "id" => "#atproto",
      "controller" => @did,
      "type" => "Multikey",
      "publicKeyMultibase" => multikey
    }

    for methods <- [
          [method, method],
          [%{method | "controller" => "did:web:foreign.example.com"}],
          []
        ] do
      request =
        Req.new(
          plug: fn conn ->
            Req.Test.json(conn, %{"id" => @did, "verificationMethod" => methods})
          end
        )

      assert {:error, :invalid_service_token} =
               ServiceTokens.authenticate(
                 token(key, claims),
                 @aud,
                 @method,
                 Keyword.put(opts, :request, request)
               )
    end

    refute Repo.exists?(ServiceTokenUse)
  end

  test "expired replay markers are pruned in bounded batches and transaction rollback permits retry" do
    {key, claims, opts} = fixture(:p256)
    token = token(key, claims)

    assert {:error, :retry} =
             Repo.transaction(fn ->
               assert {:ok, _} = ServiceTokens.authenticate(token, @aud, @method, opts)
               Repo.rollback(:retry)
             end)

    assert {:ok, _} = ServiceTokens.authenticate(token, @aud, @method, opts)

    for _ <- 1..3,
        do: Repo.insert!(%ServiceTokenUse{digest: :crypto.strong_rand_bytes(32), expires_at: 1})

    assert {:error, :invalid_limit} = ServiceTokens.prune_expired(0)
    assert {:ok, 2} = ServiceTokens.prune_expired(2)
    assert {:ok, 1} = ServiceTokens.prune_expired(2)
    assert {:ok, 0} = ServiceTokens.prune_expired()

    assert {:error, :service_token_replayed} =
             ServiceTokens.authenticate(token, @aud, @method, opts)
  end

  defp fixture(curve) do
    key = SigningKey.generate(curve)
    {:ok, multikey} = Multikey.encode(key.curve, key.public)

    doc = %{
      "id" => @did,
      "verificationMethod" => [
        %{
          "id" => "#atproto",
          "controller" => @did,
          "type" => "Multikey",
          "publicKeyMultibase" => multikey
        }
      ]
    }

    now = System.system_time(:second)

    claims = %{
      "iss" => @did,
      "aud" => @aud,
      "lxm" => @method,
      "iat" => now,
      "exp" => now + 60,
      "jti" => Base.encode16(:crypto.strong_rand_bytes(16))
    }

    opts = [
      now: now,
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      request: Req.new(plug: fn conn -> Req.Test.json(conn, doc) end)
    ]

    {key, claims, opts}
  end

  defp token(key, claims, header \\ nil) do
    header = header || %{alg: if(key.curve == :k256, do: "ES256K", else: "ES256"), typ: "JWT"}
    token_json(key, Jason.encode!(header), Jason.encode!(claims))
  end

  defp token_json(key, header, claims) do
    input =
      Base.url_encode64(header, padding: false) <>
        "." <> Base.url_encode64(claims, padding: false)

    {:ok, signature} = SigningKey.sign(key, input)
    input <> "." <> Base.url_encode64(signature, padding: false)
  end
end
