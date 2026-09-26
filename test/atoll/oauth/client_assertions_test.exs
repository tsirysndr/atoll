defmodule Atoll.OAuth.ClientAssertionsTest do
  use Atoll.DataCase, async: false
  alias Atoll.OAuth.{ClientAssertions, ClientKeys, ClientAssertionUse}
  @id "https://app.example.com/metadata.json"
  @issuer "https://pds.example.com"
  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

  setup do
    key = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, public} = JOSE.JWK.to_public_map(key)

    doc = %{
      "client_id" => @id,
      "grant_types" => ["authorization_code"],
      "response_types" => ["code"],
      "scope" => "atproto",
      "redirect_uris" => ["https://app.example.com/callback"],
      "dpop_bound_access_tokens" => true,
      "token_endpoint_auth_method" => "private_key_jwt",
      "jwks" => %{"keys" => [Map.put(public, "kid", "first")]}
    }

    opts = options(doc)
    {:ok, client} = ClientKeys.fetch(@id, opts)
    %{rows: [[now]]} = Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")

    %{
      key: key,
      doc: doc,
      opts: opts,
      client: client,
      now: now,
      header: %{"alg" => "ES256", "kid" => "first", "typ" => "JWT"},
      claims: %{
        "iss" => @id,
        "sub" => @id,
        "aud" => @issuer,
        "iat" => now,
        "exp" => now + 120,
        "jti" => "assertion-id"
      }
    }
  end

  test "verifies client identity, audience, lifetime, and original key binding", c do
    assert {:ok, verified} = verify(c)
    assert verified.client_id == @id
    assert verified.binding == %{kid: "first", alg: "ES256", jkt: JOSE.JWK.thumbprint(c.key)}
    assert {:ok, ^verified} = verify(c, binding: verified.binding)
    assert {:error, :invalid_client_assertion} = verify(c, binding: nil)

    for field <- [:kid, :alg, :jkt] do
      assert {:error, :invalid_client_assertion} =
               verify(c, binding: Map.put(verified.binding, field, "changed"))
    end

    assert {:ok, _} = verify(%{c | claims: Map.put(c.claims, "aud", [@issuer])})
    assert {:ok, _} = verify(%{c | header: Map.delete(c.header, "typ")})

    assert {:ok, _} =
             verify(%{
               c
               | claims: Map.merge(c.claims, %{"iat" => c.now - 60, "exp" => c.now + 1})
             })

    for changes <- [
          %{"iss" => "other"},
          %{"sub" => "other"},
          %{"aud" => @issuer <> "/oauth/token"},
          %{"aud" => [@issuer, "https://other.example.com"]},
          %{"iat" => c.now + 31},
          %{"iat" => c.now - 301},
          %{"iat" => c.now / 1},
          %{"exp" => c.now},
          %{"exp" => c.now + 301},
          %{"exp" => nil},
          %{"nbf" => c.now + 1},
          %{"jti" => ""},
          %{"jti" => String.duplicate("x", 257)}
        ] do
      assert {:error, :invalid_client_assertion} =
               verify(%{c | claims: Map.merge(c.claims, changes)})
    end

    for field <- Map.keys(c.claims) do
      assert {:error, :invalid_client_assertion} =
               verify(%{c | claims: Map.delete(c.claims, field)})
    end
  end

  test "rejects signature substitution, algorithm confusion, extensions, duplicate JSON and oversized JWTs",
       c do
    for header <- [
          Map.put(c.header, "typ", "dpop+jwt"),
          Map.put(c.header, "crit", ["unknown"]),
          Map.put(c.header, "jwk", %{}),
          Map.put(c.header, "jku", "https://evil.example.com"),
          Map.put(c.header, "kid", "absent")
        ] do
      assert {:error, :invalid_client_assertion} = verify(%{c | header: header})
    end

    assert {:error, :invalid_client_assertion} =
             verify(%{c | key: JOSE.JWK.generate_key({:ec, :secp256r1})})

    hs =
      JOSE.JWT.sign(JOSE.JWK.from_oct("secret"), %{"alg" => "HS256", "kid" => "first"}, c.claims)
      |> JOSE.JWS.compact()
      |> elem(1)

    [h, p, _] = String.split(token(c), ".")

    for bad <- [
          hs,
          nil,
          "a.b.c.d",
          String.duplicate("a", 8193),
          h <> "." <> p <> "." <> Base.url_encode64(<<0::512>>, padding: false)
        ] do
      assert {:error, :invalid_client_assertion} =
               ClientAssertions.verify(bad, c.client, @issuer, now: c.now)
    end

    header = Jason.encode!(c.header)
    claims = Jason.encode!(c.claims)

    for {h, p} <- [
          {String.replace_prefix(header, "{", ~s({"kid":"first",)), claims},
          {header, String.replace_prefix(claims, "{", ~s({"sub":"other",))},
          {header, String.replace_prefix(claims, "{", ~s({"extra":{"a":1,"a":2},))}
        ] do
      assert {:error, :invalid_client_assertion} =
               ClientAssertions.verify(raw_token(c.key, h, p), c.client, @issuer, now: c.now)
    end
  end

  test "admission stores only a digest, survives later rollback, and rejects alternate signatures",
       c do
    original = token(c)
    assert {:ok, authenticated} = authenticate(c, original)
    assert authenticated.metadata == c.doc |> Map.put("application_type", "web")
    assert {:error, :request_failed} = Repo.transaction(fn -> Repo.rollback(:request_failed) end)
    assert {:error, :client_assertion_replayed} = authenticate(c, original)
    [h, p, sig] = String.split(original, ".")
    {:ok, <<r::256, s::256>>} = Base.url_decode64(sig, padding: false)
    order = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

    alternative =
      h <> "." <> p <> "." <> Base.url_encode64(<<r::256, order - s::256>>, padding: false)

    assert {:ok, _} = ClientAssertions.verify(alternative, c.client, @issuer, now: c.now)
    assert {:error, :client_assertion_replayed} = authenticate(c, alternative)
    marker = Repo.one!(ClientAssertionUse)
    assert byte_size(marker.digest) == 32
    assert marker.expires_at == c.claims["exp"]
    assert {:ok, _} = authenticate(c, token(%{c | claims: Map.put(c.claims, "jti", "fresh")}))
  end

  test "fresh keys cannot bypass stored session binding or cross-key assertion replay", c do
    assert {:ok, original} = authenticate(c, token(c))
    other = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, public} = JOSE.JWK.to_public_map(other)
    doc = Map.put(c.doc, "jwks", %{"keys" => [Map.put(public, "kid", "first")]})
    changed = %{c | key: other, opts: options(doc)}

    assert {:error, :invalid_client_assertion} =
             authenticate(changed, token(changed), binding: original.binding)

    assert {:error, :client_assertion_replayed} = authenticate(changed, token(changed))
    changed = %{changed | claims: Map.put(changed.claims, "jti", "fresh")}

    assert {:error, :invalid_client_assertion} =
             authenticate(changed, token(changed), binding: original.binding)

    assert {:ok, _} = authenticate(changed, token(changed))

    removed = %{
      c
      | opts: options(Map.put(c.doc, "jwks", %{"keys" => [Map.put(public, "kid", "second")]}))
    }

    assert {:error, :invalid_client_assertion} =
             authenticate(removed, token(c), binding: original.binding)
  end

  test "nested transactions and wrong assertion types are rejected before fetching", c do
    opts = [lookup: fn _ -> flunk("unexpected network access") end]

    assert {:error, :invalid_client_assertion} =
             ClientAssertions.authenticate(@id, "wrong", token(c), @issuer, opts)

    assert {:error, :invalid_client_assertion} =
             ClientAssertions.authenticate(
               @id,
               @assertion_type,
               String.duplicate("x", 8193),
               @issuer,
               opts
             )

    assert {:ok, {:error, :oauth_assertion_inside_transaction}} =
             Repo.transaction(fn ->
               ClientAssertions.authenticate(@id, @assertion_type, token(c), @issuer, opts)
             end)

    assert {:error, :invalid_client_assertion} =
             authenticate(c, token(%{c | claims: Map.put(c.claims, "exp", c.now - 1)}))

    assert Repo.aggregate(ClientAssertionUse, :count) == 0
  end

  test "independent database transactions admit a concurrent assertion once", c do
    jti = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    c = %{c | claims: Map.put(c.claims, "jti", jti)}
    assertion = token(c)

    digest =
      :crypto.hash(
        :sha256,
        Atoll.CBOR.encode!(["atoll.oauth.client-assertion-use.v1", @issuer, @id, jti])
      )

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from u in ClientAssertionUse, where: u.digest == ^digest)
      end)
    end)

    supervisor = start_supervised!(Task.Supervisor)

    results =
      Task.Supervisor.async_stream_nolink(
        supervisor,
        1..4,
        fn _ ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> authenticate(c, assertion) end)
        end,
        max_concurrency: 4,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :client_assertion_replayed})) == 3
  end

  test "full replay storage fails closed and expired reclamation is bounded", c do
    Repo.insert_all(
      ClientAssertionUse,
      for(i <- 1..1005, do: %{digest: <<i::256>>, expires_at: c.now - 1})
    )

    assert {:ok, _} = authenticate(c, token(c))
    assert Repo.aggregate(ClientAssertionUse, :count) == 6
    Repo.delete_all(ClientAssertionUse)

    for chunk <- Enum.chunk_every(1..100_000, 10_000) do
      Repo.insert_all(
        ClientAssertionUse,
        Enum.map(chunk, &%{digest: <<&1::256>>, expires_at: c.now + 600}),
        log: false
      )
    end

    assert {:error, :oauth_assertion_store_full} = authenticate(c, token(c))

    Repo.get!(ClientAssertionUse, <<1::256>>)
    |> Ecto.Changeset.change(expires_at: c.now - 1)
    |> Repo.update!()

    assert {:ok, _} = authenticate(c, token(c))
    assert Repo.aggregate(ClientAssertionUse, :count) == 100_000
  end

  defp options(doc),
    do: [
      request: Req.new(plug: fn conn -> Req.Test.json(conn, doc) end),
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end
    ]

  defp verify(c, opts \\ []),
    do: ClientAssertions.verify(token(c), c.client, @issuer, [now: c.now] ++ opts)

  defp authenticate(c, assertion, opts \\ []),
    do: ClientAssertions.authenticate(@id, @assertion_type, assertion, @issuer, c.opts ++ opts)

  defp token(c), do: JOSE.JWT.sign(c.key, c.header, c.claims) |> JOSE.JWS.compact() |> elem(1)

  defp raw_token(key, header, claims) do
    h = Base.url_encode64(header, padding: false)
    p = Base.url_encode64(claims, padding: false)
    {_, jwk} = JOSE.JWK.to_map(key)
    {:ok, private} = Base.url_decode64(jwk["d"], padding: false)
    der = :crypto.sign(:ecdsa, :sha256, h <> "." <> p, [private, :secp256r1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    h <> "." <> p <> "." <> Base.url_encode64(<<r::256, s::256>>, padding: false)
  end
end
