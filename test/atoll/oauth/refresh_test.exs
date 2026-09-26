defmodule Atoll.OAuth.RefreshTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Repositories, SigningKey}
  alias Atoll.Accounts.Sessions

  alias Atoll.OAuth.{
    PAR,
    Nonce,
    AuthorizationCodes,
    CodeExchange,
    Session,
    AccessToken,
    ProofUse,
    RefreshUse,
    Refresh
  }

  @id "https://app.example.com/metadata.json"
  @issuer "https://pds.example.com"

  setup tags do
    did = "did:plc:codeexchange"
    {:ok, head} = Repositories.create(did, SigningKey.generate())
    session_opts = [secret: :crypto.strong_rand_bytes(32), audience: "did:web:pds.example.com"]
    {:ok, pair} = Sessions.create_for_account(did, session_opts)

    metadata = %{
      "client_id" => @id,
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "scope" => "atproto",
      "redirect_uris" => ["https://app.example.com/callback"],
      "dpop_bound_access_tokens" => true
    }

    opts =
      [issuer: @issuer, secret: :crypto.strong_rand_bytes(32), session_options: session_opts] ++
        transport(metadata)

    {:ok, nonce} = Nonce.issue(:authorization, opts)

    c = %{
      did: did,
      head: head,
      pair: pair,
      opts: opts,
      metadata: metadata,
      nonce: nonce,
      key: JOSE.JWK.generate_key({:ec, :secp256r1})
    }

    if tags[:independent] do
      c
    else
      c = grant(c)
      {:ok, tokens} = exchange(c)
      Map.put(c, :tokens, tokens)
    end
  end

  test "rotation retains bindings and expiry, storing token hashes and per-access scope", c do
    session = Repo.one!(Session)
    assert {:ok, tokens} = refresh(c, c.tokens.refresh_token)
    refute tokens.refresh_token == c.tokens.refresh_token
    refute tokens.access_token == c.tokens.access_token
    assert tokens.scope == session.scope
    assert tokens.sub == session.did
    assert tokens.token_type == "DPoP"
    assert tokens.expires_in == 300
    updated = Repo.get!(Session, session.id)
    assert updated.expires_at == session.expires_at
    assert updated.refresh_digest == :crypto.hash(:sha256, tokens.refresh_token)
    assert updated.client_id == session.client_id
    assert updated.dpop_jkt == session.dpop_jkt
    assert Repo.one!(RefreshUse).digest == :crypto.hash(:sha256, c.tokens.refresh_token)
    assert Repo.one!(RefreshUse).expires_at == session.expires_at
    assert Repo.get!(AccessToken, :crypto.hash(:sha256, tokens.access_token)).scope == "atproto"
    assert Repo.aggregate(AccessToken, :count) == 2
    assert {:ok, _} = refresh(c, tokens.refresh_token)
  end

  test "verified reuse revokes the entire family and incorrect client or DPoP cannot", c do
    assert {:ok, tokens} = refresh(c, c.tokens.refresh_token)

    assert {:error, :invalid_grant} =
             refresh(c, c.tokens.refresh_token, %{"client_id" => "https://other.example.com"})

    assert {:error, :invalid_grant} =
             refresh(%{c | key: JOSE.JWK.generate_key({:ec, :secp256r1})}, c.tokens.refresh_token)

    assert Repo.aggregate(Session, :count) == 1
    assert {:error, :invalid_grant} = refresh(c, c.tokens.refresh_token)
    assert Repo.aggregate(Session, :count) == 0
    assert Repo.aggregate(AccessToken, :count) == 0
    assert Repo.aggregate(RefreshUse, :count) == 0
    assert {:error, :invalid_grant} = refresh(c, tokens.refresh_token)
  end

  test "scope narrowing affects only the new access token and cannot expand the grant", c do
    session = Repo.one!(Session)

    session
    |> Ecto.Changeset.change(scope: "atproto transition:generic transition:email")
    |> Repo.update!()

    metadata = Map.put(c.metadata, "scope", "atproto transition:generic transition:email")
    c = %{c | opts: Keyword.merge(c.opts, transport(metadata))}

    assert {:error, :invalid_scope} =
             refresh(c, c.tokens.refresh_token, %{"scope" => "atproto transition:chat.bsky"})

    assert {:ok, tokens} =
             refresh(c, c.tokens.refresh_token, %{"scope" => "atproto transition:email"})

    assert tokens.scope == "atproto transition:email"

    assert Repo.get!(AccessToken, :crypto.hash(:sha256, tokens.access_token)).scope ==
             tokens.scope

    assert Repo.one!(Session).scope == metadata["scope"]
    assert {:ok, full} = refresh(c, tokens.refresh_token)
    assert full.scope == metadata["scope"]
  end

  test "expired sessions and source-session revocation block refresh", c do
    session = Repo.one!(Session)
    session |> Ecto.Changeset.change(expires_at: 1) |> Repo.update!()
    assert {:error, :invalid_grant} = refresh(c, c.tokens.refresh_token)

    Repo.get!(Session, session.id)
    |> Ecto.Changeset.change(expires_at: session.expires_at)
    |> Repo.update!()

    assert {:ok, _} = refresh(c, c.tokens.refresh_token)
    assert {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt, c.opts[:session_options])
    assert Repo.aggregate(Session, :count) == 0
    assert Repo.aggregate(AccessToken, :count) == 0
    assert Repo.aggregate(RefreshUse, :count) == 0
  end

  test "revocation during metadata retrieval is rechecked before rotation", c do
    request =
      Req.new(
        plug: fn conn ->
          Repo.delete_all(Atoll.Accounts.Session)
          Req.Test.json(conn, c.metadata)
        end
      )

    assert {:error, :invalid_grant} =
             refresh(%{c | opts: Keyword.put(c.opts, :request, request)}, c.tokens.refresh_token)

    assert Repo.aggregate(Session, :count) == 0
  end

  test "bounded access storage rolls back rotation and later prunes expired access tokens", c do
    session = Repo.one!(Session)

    rows =
      for _ <- 1..99,
          do: %{
            digest: :crypto.strong_rand_bytes(32),
            session_id: session.id,
            scope: session.scope,
            expires_at: System.system_time(:second) + 300
          }

    Repo.insert_all(AccessToken, rows)
    assert {:error, :oauth_refresh_store_full} = refresh(c, c.tokens.refresh_token)
    assert Repo.one!(Session).refresh_digest == session.refresh_digest
    assert Repo.aggregate(RefreshUse, :count) == 0
    Repo.update_all(AccessToken, set: [expires_at: 1])
    assert {:ok, _} = refresh(c, c.tokens.refresh_token)
    assert Repo.aggregate(AccessToken, :count) == 1
  end

  test "invalid requests, assertions for public clients and reused proofs cannot rotate", c do
    assert {:error, :invalid_request} = refresh(c, "wrong")

    assert {:error, :invalid_request} =
             refresh(c, c.tokens.refresh_token, %{"redirect_uri" => "https://app.example.com"})

    assert {:error, :invalid_client} =
             refresh(c, c.tokens.refresh_token, %{"client_assertion" => "bad"})

    params = refresh_params(c, c.tokens.refresh_token, %{})
    signed = proof(c, "/oauth/token")
    assert {:ok, _} = Refresh.exchange(params, [signed], c.opts)
    assert {:error, :dpop_replayed} = Refresh.exchange(params, [signed], c.opts)
    assert Repo.aggregate(Session, :count) == 1

    assert {:ok, {:error, :oauth_refresh_inside_transaction}} =
             Repo.transaction(fn -> refresh(c, c.tokens.refresh_token) end)
  end

  test "global replay capacity fails atomically and expired markers are reclaimed", c do
    session = Repo.one!(Session)

    Repo.query!(
      """
      INSERT INTO oauth_refresh_uses (digest, session_id, expires_at)
      SELECT decode(lpad(to_hex(i), 64, '0'), 'hex'), $1, $2
      FROM generate_series(1, 100000) AS i
      """,
      [session.id, session.expires_at],
      log: false
    )

    assert {:error, :oauth_refresh_store_full} = refresh(c, c.tokens.refresh_token)
    assert Repo.one!(Session).refresh_digest == session.refresh_digest
    assert Repo.aggregate(AccessToken, :count) == 1
    Repo.update_all(from(u in RefreshUse, where: u.digest == ^<<1::256>>), set: [expires_at: 1])
    assert {:ok, _} = refresh(c, c.tokens.refresh_token)
    assert Repo.aggregate(RefreshUse, :count) == 100_000
    refute Repo.get(RefreshUse, <<1::256>>)
  end

  test "account status and current source expiry constrain refreshed tokens", c do
    Repo.get!(Atoll.Repositories.Head, c.did)
    |> Ecto.Changeset.change(status: :deactivated)
    |> Repo.update!()

    assert {:error, :invalid_grant} = refresh(c, c.tokens.refresh_token)

    Repo.get!(Atoll.Repositories.Head, c.did)
    |> Ecto.Changeset.change(status: :active)
    |> Repo.update!()

    Repo.one!(Atoll.Accounts.Session)
    |> Ecto.Changeset.change(expires_at: System.system_time(:second) + 60)
    |> Repo.update!()

    assert {:ok, tokens} = refresh(c, c.tokens.refresh_token)
    assert tokens.expires_in in 58..60
    Repo.one!(Atoll.Accounts.Session) |> Ecto.Changeset.change(expires_at: 1) |> Repo.update!()
    assert {:error, :invalid_grant} = refresh(c, tokens.refresh_token)
  end

  test "confidential clients authenticate with original key; observed key removal revokes", c do
    for mode <- [:empty, :replacement] do
      key = JOSE.JWK.generate_key({:ec, :secp256r1})
      {_, public} = JOSE.JWK.to_public_map(key)

      metadata =
        Map.merge(c.metadata, %{
          "token_endpoint_auth_method" => "private_key_jwt",
          "jwks" => %{"keys" => [Map.put(public, "kid", "client-key")]}
        })

      confidential =
        grant(Map.merge(c, %{auth_key: key, opts: Keyword.merge(c.opts, transport(metadata))}))

      {:ok, tokens} = exchange(confidential)

      assert {:error, :invalid_client_assertion} =
               refresh(
                 %{confidential | auth_key: JOSE.JWK.generate_key({:ec, :secp256r1})},
                 tokens.refresh_token
               )

      assert {:ok, rotated} = refresh(confidential, tokens.refresh_token)
      session = Repo.one!(from s in Session, where: not is_nil(s.client_binding))
      # A transient fetch failure rejects refresh but does not permanently revoke.
      failed = Keyword.put(confidential.opts, :lookup, fn _ -> {:error, :nxdomain} end)

      assert {:error, :invalid_client_keys} =
               refresh(%{confidential | opts: failed}, rotated.refresh_token)

      assert Repo.get(Session, session.id)
      {_, other} = JOSE.JWK.generate_key({:ec, :secp256r1}) |> JOSE.JWK.to_public_map()
      keys = if mode == :empty, do: [], else: [Map.put(other, "kid", "client-key")]
      removed = Map.put(metadata, "jwks", %{"keys" => keys})
      changed = %{confidential | opts: Keyword.merge(confidential.opts, transport(removed))}
      assert {:error, :invalid_grant} = refresh(changed, rotated.refresh_token)
      refute Repo.get(Session, session.id)
      assert {:error, :invalid_grant} = refresh(confidential, rotated.refresh_token)
    end
  end

  @tag :independent
  test "concurrent refreshes rotate once then revoke on verified reuse", c do
    did = "did:plc:exchange#{System.unique_integer([:positive])}"
    key = SigningKey.generate()
    {:ok, tree} = Atoll.MST.new()
    {:ok, commit} = Atoll.Commit.create(did, tree.root, c.head.rev, key)
    token = "atoll_refresh_" <> random()

    params = %{"grant_type" => "refresh_token", "client_id" => @id, "refresh_token" => token}

    headers = for _ <- 1..2, do: proof(c, "/oauth/token")

    proof_digests =
      Enum.map(headers, fn token ->
        [_, payload, _] = String.split(token, ".")
        claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()

        :crypto.hash(
          :sha256,
          Atoll.CBOR.encode!([
            "atoll.oauth.dpop-use.v1",
            @issuer,
            "authorization",
            JOSE.JWK.thumbprint(c.key),
            claims["jti"]
          ])
        )
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from h in Atoll.Repositories.Head, where: h.did == ^did)
        Repo.delete_all(from b in Atoll.Storage.Block, where: b.cid == ^commit.cid)
        Repo.delete_all(from p in ProofUse, where: p.digest in ^proof_digests)
      end)
    end)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      :ok = Atoll.Storage.put_block(commit.cid, commit.bytes)

      Repo.insert!(%Atoll.Repositories.Head{
        did: did,
        head: commit.cid,
        rev: c.head.rev,
        curve: key.curve,
        public_key: key.public
      })

      {:ok, pair} = Sessions.create_for_account(did, c.opts[:session_options])

      {:ok, claims} =
        Atoll.Accounts.Tokens.verify(pair.access_jwt, :access, c.opts[:session_options])

      Repo.insert!(%Session{
        id: random(),
        did: did,
        source_session_id: claims["sid"],
        issuer: @issuer,
        client_id: @id,
        scope: "atproto",
        dpop_jkt: JOSE.JWK.thumbprint(c.key),
        refresh_digest: :crypto.hash(:sha256, token),
        expires_at: System.system_time(:second) + 3600
      })
    end)

    supervisor = start_supervised!(Task.Supervisor)

    results =
      Task.Supervisor.async_stream_nolink(
        supervisor,
        headers,
        fn header ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Refresh.exchange(params, [header], c.opts)
          end)
        end,
        max_concurrency: 2,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)
    assert Enum.count(results, &(&1 == {:error, :invalid_grant})) == 1

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      refute Repo.exists?(from s in Session, where: s.did == ^did)

      assert Repo.aggregate(
               from(u in RefreshUse, where: u.digest == ^:crypto.hash(:sha256, token)),
               :count
             ) == 0
    end)
  end

  defp refresh(c, token, changes \\ %{}),
    do: Refresh.exchange(refresh_params(c, token, changes), [proof(c, "/oauth/token")], c.opts)

  defp refresh_params(c, token, changes),
    do:
      %{"grant_type" => "refresh_token", "client_id" => @id, "refresh_token" => token}
      |> Map.merge(assertion(c))
      |> Map.merge(changes)

  defp grant(c) do
    verifier = random()

    params =
      %{
        "client_id" => @id,
        "response_type" => "code",
        "redirect_uri" => "https://app.example.com/callback",
        "scope" => "atproto",
        "state" => "state",
        "code_challenge_method" => "S256",
        "code_challenge" => hash(verifier)
      }
      |> Map.merge(assertion(c))

    {:ok, %{request_uri: uri}} = PAR.push(params, [proof(c, "/oauth/par")], c.opts)

    {:ok, result} =
      AuthorizationCodes.decide(c.pair.access_jwt, @id, uri, {:approve, "atproto"}, c.opts)

    Map.put(c, :params, %{
      "grant_type" => "authorization_code",
      "client_id" => @id,
      "code" => result.code,
      "redirect_uri" => params["redirect_uri"],
      "code_verifier" => verifier
    })
  end

  defp assertion(%{auth_key: key}) do
    now = System.system_time(:second)

    token =
      JOSE.JWT.sign(key, %{"alg" => "ES256", "kid" => "client-key"}, %{
        "iss" => @id,
        "sub" => @id,
        "aud" => @issuer,
        "iat" => now,
        "exp" => now + 120,
        "jti" => random()
      })
      |> JOSE.JWS.compact()
      |> elem(1)

    %{
      "client_assertion" => token,
      "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
    }
  end

  defp assertion(_), do: %{}

  defp exchange(c),
    do:
      CodeExchange.exchange(Map.merge(c.params, assertion(c)), [proof(c, "/oauth/token")], c.opts)

  defp transport(doc),
    do: [
      request: Req.new(plug: fn conn -> Req.Test.json(conn, doc) end),
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end
    ]

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)

  defp proof(c, path) do
    {_, public} = JOSE.JWK.to_public_map(c.key)

    JOSE.JWT.sign(c.key, %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public}, %{
      "jti" => random(),
      "iat" => System.system_time(:second),
      "nonce" => c.nonce,
      "htm" => "POST",
      "htu" => @issuer <> path
    })
    |> JOSE.JWS.compact()
    |> elem(1)
  end
end
