defmodule Atoll.OAuth.CodeExchangeTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Repositories, SigningKey}
  alias Atoll.Accounts.Sessions

  alias Atoll.OAuth.{
    PAR,
    Nonce,
    AuthorizationCodes,
    AuthorizationCode,
    CodeExchange,
    Session,
    AccessToken,
    ProofUse
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

    if tags[:independent], do: c, else: grant(c)
  end

  test "exchanges a bound code into opaque DPoP tokens and stores only digests", c do
    assert {:ok, result} = exchange(c)
    assert result.sub == c.did
    assert result.scope == "atproto"
    assert result.token_type == "DPoP"
    assert result.expires_in == 300
    assert String.starts_with?(result.access_token, "atoll_access_")
    assert String.starts_with?(result.refresh_token, "atoll_refresh_")
    session = Repo.one!(Session)
    assert session.client_id == @id
    assert session.dpop_jkt == JOSE.JWK.thumbprint(c.key)
    assert session.refresh_digest == :crypto.hash(:sha256, result.refresh_token)
    assert (session.expires_at - System.system_time(:second)) in (14 * 86_400 - 2)..(14 * 86_400)
    assert Repo.one!(AccessToken).digest == :crypto.hash(:sha256, result.access_token)
    code = Repo.get!(AuthorizationCode, :crypto.hash(:sha256, c.params["code"]))
    assert code.redeemed_session_id == session.id
    assert code.replay_until == session.expires_at
    assert code.redeemed_at > 0
  end

  test "incorrect bindings or DPoP keys issue no tokens and do not consume the code", c do
    for changes <- [
          %{"client_id" => "https://other.example.com"},
          %{"redirect_uri" => "https://app.example.com/other"},
          %{"code" => random()},
          %{"code_verifier" => random()}
        ] do
      assert {:error, :invalid_grant} = exchange(%{c | params: Map.merge(c.params, changes)})
    end

    assert {:error, :invalid_grant} =
             exchange(%{c | key: JOSE.JWK.generate_key({:ec, :secp256r1})})

    assert {:error, :invalid_dpop_proof} = CodeExchange.exchange(c.params, [], c.opts)

    assert {:error, :invalid_request} =
             exchange(%{c | params: Map.put(c.params, "scope", "atproto")})

    assert {:ok, {:error, :oauth_exchange_inside_transaction}} =
             Repo.transaction(fn -> exchange(c) end)

    assert Repo.aggregate(Session, :count) == 0
    assert Repo.one!(AuthorizationCode).redeemed_at == nil
    assert {:ok, _} = exchange(c)
  end

  test "verified reuse revokes issued session and tokens but a bad verifier cannot revoke", c do
    assert {:ok, _} = exchange(c)

    assert {:error, :invalid_grant} =
             exchange(%{c | params: Map.put(c.params, "code_verifier", random())})

    assert Repo.aggregate(Session, :count) == 1
    assert {:error, :invalid_grant} = exchange(c)
    assert Repo.aggregate(Session, :count) == 0
    assert Repo.aggregate(AccessToken, :count) == 0
    assert Repo.one!(AuthorizationCode).redeemed_at != nil
    assert Repo.one!(AuthorizationCode).redeemed_session_id == nil
    assert {:error, :invalid_grant} = exchange(c)
  end

  test "redeemed markers survive original code expiry and approval cleanup", c do
    assert {:ok, _} = exchange(c)
    code = Repo.one!(AuthorizationCode)
    code |> Ecto.Changeset.change(expires_at: 1) |> Repo.update!()
    _other = grant(c)
    assert Repo.get!(AuthorizationCode, code.digest).redeemed_at != nil
    assert {:error, :invalid_grant} = exchange(c)
    assert Repo.aggregate(Session, :count) == 0
  end

  test "account/source-session revocation and expired codes fail closed", c do
    code = Repo.one!(AuthorizationCode)
    code |> Ecto.Changeset.change(expires_at: 1) |> Repo.update!()
    assert {:error, :invalid_grant} = exchange(c)

    Repo.get!(AuthorizationCode, code.digest)
    |> Ecto.Changeset.change(expires_at: System.system_time(:second) + 120)
    |> Repo.update!()

    Repo.get!(Atoll.Repositories.Head, c.did)
    |> Ecto.Changeset.change(status: :deactivated)
    |> Repo.update!()

    assert {:error, :invalid_grant} = exchange(c)

    Repo.get!(Atoll.Repositories.Head, c.did)
    |> Ecto.Changeset.change(status: :active)
    |> Repo.update!()

    assert {:ok, _} = exchange(c)
    assert {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt, c.opts[:session_options])
    assert Repo.aggregate(Session, :count) == 0
    assert Repo.aggregate(AccessToken, :count) == 0
    assert {:error, :invalid_grant} = exchange(c)
  end

  test "access-only clients get no refresh token and source expiry bounds token lifetime", c do
    metadata = Map.put(c.metadata, "grant_types", ["authorization_code"])
    c = grant(%{c | opts: Keyword.merge(c.opts, transport(metadata)), metadata: metadata})
    source = Repo.one!(Atoll.Accounts.Session)

    source
    |> Ecto.Changeset.change(expires_at: System.system_time(:second) + 60)
    |> Repo.update!()

    assert {:ok, result} = exchange(c)
    refute Map.has_key?(result, :refresh_token)
    assert result.expires_in in 58..60
    assert Repo.one!(Session).refresh_digest == nil
  end

  test "changed client metadata cannot expand or invalidate the approved grant", c do
    for metadata <- [
          Map.put(c.metadata, "redirect_uris", ["https://app.example.com/other"]),
          Map.put(c.metadata, "grant_types", ["authorization_code"])
        ] do
      assert {:error, :invalid_grant} =
               exchange(%{c | opts: Keyword.merge(c.opts, transport(metadata))})
    end

    assert Repo.aggregate(Session, :count) == 0
    assert Repo.one!(AuthorizationCode).redeemed_at == nil
    assert {:ok, result} = exchange(c)
    assert result.scope == "atproto"
  end

  test "confidential clients must retain and prove the original key", c do
    key = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, public} = JOSE.JWK.to_public_map(key)

    metadata =
      Map.merge(c.metadata, %{
        "token_endpoint_auth_method" => "private_key_jwt",
        "jwks" => %{"keys" => [Map.put(public, "kid", "client-key")]}
      })

    c = grant(Map.merge(c, %{auth_key: key, opts: Keyword.merge(c.opts, transport(metadata))}))
    other = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, replacement} = JOSE.JWK.to_public_map(other)
    changed = Map.put(metadata, "jwks", %{"keys" => [Map.put(replacement, "kid", "client-key")]})

    assert {:error, :invalid_client_assertion} =
             exchange(%{c | auth_key: other, opts: Keyword.merge(c.opts, transport(changed))})

    assert {:ok, _} = exchange(c)
    assert Repo.one!(Session).client_binding["jkt"] == JOSE.JWK.thumbprint(key)
    assert Repo.one!(Session).expires_at == Repo.one!(Atoll.Accounts.Session).expires_at
  end

  test "account session cap rolls back code redemption", c do
    assert {:ok, _} = exchange(c)
    session = Repo.one!(Session) |> Map.from_struct() |> Map.drop([:__meta__])
    rows = for _ <- 1..99, do: Map.merge(session, %{id: random(), refresh_digest: nil})
    Repo.insert_all(Session, rows, log: false)
    c = grant(c)
    assert {:error, :oauth_session_limit} = exchange(c)
    code = Repo.get!(AuthorizationCode, :crypto.hash(:sha256, c.params["code"]))
    assert code.redeemed_at == nil
    assert Repo.aggregate(Session, :count) == 100
  end

  @tag :independent
  test "concurrent code exchanges issue once then revoke on verified reuse", c do
    did = "did:plc:exchange#{System.unique_integer([:positive])}"
    key = SigningKey.generate()
    {:ok, tree} = Atoll.MST.new()
    {:ok, commit} = Atoll.Commit.create(did, tree.root, c.head.rev, key)
    code = random()
    verifier = random()

    params = %{
      "grant_type" => "authorization_code",
      "client_id" => @id,
      "code" => code,
      "code_verifier" => verifier,
      "redirect_uri" => "https://app.example.com/callback"
    }

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

      Repo.insert!(%AuthorizationCode{
        digest: :crypto.hash(:sha256, code),
        did: did,
        source_session_id: claims["sid"],
        issuer: @issuer,
        client_id: @id,
        redirect_uri: params["redirect_uri"],
        scope: "atproto",
        code_challenge: hash(verifier),
        dpop_jkt: JOSE.JWK.thumbprint(c.key),
        refresh_allowed: true,
        expires_at: System.system_time(:second) + 120
      })
    end)

    supervisor = start_supervised!(Task.Supervisor)

    results =
      Task.Supervisor.async_stream_nolink(
        supervisor,
        headers,
        fn header ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            CodeExchange.exchange(params, [header], c.opts)
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
      assert Repo.get!(AuthorizationCode, :crypto.hash(:sha256, code)).redeemed_session_id == nil
    end)
  end

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
