defmodule Atoll.OAuth.AuthorizationCodesTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Repositories, SigningKey}
  alias Atoll.Repositories.Head
  alias Atoll.Accounts.{Sessions, Session}
  alias Atoll.OAuth.{PAR, Nonce, PushedRequest, PKCEUse, AuthorizationCodes, AuthorizationCode}
  @id "https://app.example.com/metadata.json"
  @issuer "https://pds.example.com"

  setup do
    did = "did:plc:oauthconsent"
    {:ok, head} = Repositories.create(did, SigningKey.generate())
    session_opts = [secret: :crypto.strong_rand_bytes(32), audience: "did:web:pds.example.com"]
    {:ok, pair} = Sessions.create_for_account(did, session_opts)

    metadata = %{
      "client_id" => @id,
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "scope" => "atproto transition:generic transition:email transition:chat.bsky",
      "redirect_uris" => ["https://app.example.com/callback"],
      "dpop_bound_access_tokens" => true
    }

    opts =
      [issuer: @issuer, secret: :crypto.strong_rand_bytes(32), session_options: session_opts] ++
        transport(metadata)

    {:ok, nonce} = Nonce.issue(:authorization, opts)

    %{
      did: did,
      head: head,
      pair: pair,
      opts: opts,
      metadata: metadata,
      nonce: nonce,
      key: JOSE.JWK.generate_key({:ec, :secp256r1})
    }
  end

  test "approval consumes the request and stores only a bound short-lived code digest", c do
    uri = pushed(c)
    assert {:ok, request} = PAR.get(@id, uri, c.opts)
    assert {:ok, result} = decide(c, uri, {:approve, "atproto"})
    assert result.redirect_uri == request.parameters["redirect_uri"]
    assert result.state == request.parameters["state"]
    assert result.iss == @issuer
    code = Repo.one!(AuthorizationCode)
    assert code.digest == :crypto.hash(:sha256, result.code)
    assert byte_size(result.code) == 43
    assert code.did == c.did
    assert code.client_id == @id
    assert code.issuer == @issuer
    assert code.scope == "atproto"
    assert code.refresh_allowed
    assert code.dpop_jkt == request.dpop_jkt
    assert code.code_challenge == request.parameters["code_challenge"]
    assert code.client_binding == nil
    assert (code.expires_at - System.system_time(:second)) in 118..120
    assert {:error, :invalid_request_uri} = PAR.get(@id, uri, c.opts)
    assert {:error, :invalid_request_uri} = decide(c, uri, {:approve, "atproto"})
    assert Repo.aggregate(PKCEUse, :count) == 1
  end

  test "denial consumes the request without a code and cannot be changed into approval", c do
    uri = pushed(c)
    assert {:ok, %{error: "access_denied", state: "state", iss: @issuer}} = decide(c, uri, :deny)
    assert Repo.aggregate(AuthorizationCode, :count) == 0
    assert {:error, :invalid_request_uri} = decide(c, uri, {:approve, "atproto"})
  end

  test "requires a full live session and active account without consuming on failure", c do
    uri = pushed(c)
    assert {:error, _} = AuthorizationCodes.decide("bad", @id, uri, {:approve, "atproto"}, c.opts)

    password =
      Repo.insert!(%Atoll.Accounts.AppPassword{
        did: c.did,
        name: "test-app",
        digest: :crypto.strong_rand_bytes(32)
      })

    {:ok, app} =
      Sessions.create_for_account(
        c.did,
        c.opts[:session_options] ++
          [access_scope: "com.atproto.appPass", app_password_id: password.id]
      )

    assert {:error, :forbidden} =
             AuthorizationCodes.decide(app.access_jwt, @id, uri, {:approve, "atproto"}, c.opts)

    Repo.get!(Head, c.did) |> Ecto.Changeset.change(status: :deactivated) |> Repo.update!()
    assert {:error, :account_unavailable} = decide(c, uri, {:approve, "atproto"})
    Repo.get!(Head, c.did) |> Ecto.Changeset.change(status: :active) |> Repo.update!()
    assert {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt, c.opts[:session_options])
    assert {:error, :invalid_token} = decide(c, uri, {:approve, "atproto"})
    assert {:ok, _} = PAR.get(@id, uri, c.opts)
    assert Repo.aggregate(AuthorizationCode, :count) == 0
  end

  test "scope escalation, expiry, wrong client/issuer, and nested calls fail without issuance",
       c do
    uri = pushed(c)

    for scope <- [
          "",
          "transition:generic",
          "atproto unknown",
          "atproto transition:chat.bsky",
          ["atproto"]
        ] do
      assert {:error, :invalid_scope} = decide(c, uri, {:approve, scope})
    end

    assert {:error, :invalid_consent} = decide(c, uri, true)

    assert {:error, :invalid_request_uri} =
             AuthorizationCodes.decide(
               c.pair.access_jwt,
               "https://other.example.com",
               uri,
               :deny,
               c.opts
             )

    assert {:error, :invalid_request_uri} =
             AuthorizationCodes.decide(
               c.pair.access_jwt,
               @id,
               uri,
               :deny,
               Keyword.put(c.opts, :issuer, "https://other.example.com")
             )

    assert {:ok, {:error, :oauth_authorization_inside_transaction}} =
             Repo.transaction(fn -> decide(c, uri, :deny) end)

    Repo.one!(PushedRequest) |> Ecto.Changeset.change(expires_at: 1) |> Repo.update!()
    assert {:error, :invalid_request_uri} = decide(c, uri, {:approve, "atproto"})
    assert Repo.aggregate(AuthorizationCode, :count) == 0
  end

  test "rechecks client policy and revocation after network retrieval", c do
    uri = pushed(c)
    changed = Map.put(c.metadata, "redirect_uris", ["https://app.example.com/other"])

    assert {:error, :invalid_client} =
             decide(
               %{c | opts: Keyword.merge(c.opts, transport(changed))},
               uri,
               {:approve, "atproto"}
             )

    request =
      Req.new(
        plug: fn conn ->
          Repo.delete_all(Session)
          Req.Test.json(conn, c.metadata)
        end
      )

    assert {:error, :invalid_token} =
             decide(
               %{c | opts: Keyword.put(c.opts, :request, request)},
               uri,
               {:approve, "atproto"}
             )

    assert {:ok, _} = PAR.get(@id, uri, c.opts)
    assert Repo.aggregate(AuthorizationCode, :count) == 0
  end

  test "source session revocation removes pending codes through the foreign key", c do
    assert {:ok, _} = decide(c, pushed(c), {:approve, "atproto"})
    assert {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt, c.opts[:session_options])
    assert Repo.aggregate(AuthorizationCode, :count) == 0
  end

  test "capacity failure keeps the request available and expired codes release capacity", c do
    assert {:ok, _} = decide(c, pushed(c), {:approve, "atproto"})
    code = Repo.one!(AuthorizationCode)
    attrs = code |> Map.from_struct() |> Map.drop([:__meta__])
    Repo.delete_all(AuthorizationCode)

    for chunk <- Enum.chunk_every(1..10_000, 1000) do
      Repo.insert_all(AuthorizationCode, Enum.map(chunk, &Map.put(attrs, :digest, <<&1::256>>)),
        log: false
      )
    end

    uri = pushed(c)
    assert {:error, :oauth_code_store_full} = decide(c, uri, {:approve, "atproto"})
    assert {:ok, _} = PAR.get(@id, uri, c.opts)

    Repo.get!(AuthorizationCode, <<1::256>>)
    |> Ecto.Changeset.change(expires_at: 1)
    |> Repo.update!()

    assert {:ok, _} = decide(c, uri, {:approve, "atproto"})
    assert Repo.aggregate(AuthorizationCode, :count) == 10_000
  end

  test "independent concurrent approvals consume a pushed request only once", c do
    # Seed a committed request without retaining PAR's advisory lock in the
    # outer sandbox transaction; all contenders must acquire real DB locks.
    snapshot = %PushedRequest{
      issuer: @issuer,
      client_id: @id,
      parameters: %{
        "client_id" => @id,
        "response_type" => "code",
        "scope" => "atproto",
        "redirect_uri" => "https://app.example.com/callback",
        "state" => "state",
        "code_challenge_method" => "S256",
        "code_challenge" => random()
      },
      dpop_jkt: JOSE.JWK.thumbprint(c.key),
      expires_at: System.system_time(:second) + 90
    }

    did = "did:plc:consent#{System.unique_integer([:positive])}"
    uri = "urn:ietf:params:oauth:request_uri:" <> random()
    digest = :crypto.hash(:sha256, uri)
    key = SigningKey.generate()
    {:ok, tree} = Atoll.MST.new()
    {:ok, commit} = Atoll.Commit.create(did, tree.root, c.head.rev, key)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from r in PushedRequest, where: r.digest == ^digest)
        Repo.delete_all(from h in Head, where: h.did == ^did)
        Repo.delete_all(from b in Atoll.Storage.Block, where: b.cid == ^commit.cid)
      end)
    end)

    pair =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        # Minimal committed account metadata for authorization, independent of
        # the outer sandbox's repository blocks and event-sequencer lock.
        :ok = Atoll.Storage.put_block(commit.cid, commit.bytes)

        Repo.insert!(%Head{
          did: did,
          head: commit.cid,
          rev: c.head.rev,
          curve: key.curve,
          public_key: key.public
        })

        {:ok, pair} = Sessions.create_for_account(did, c.opts[:session_options])

        Repo.insert!(%PushedRequest{
          digest: digest,
          issuer: snapshot.issuer,
          client_id: snapshot.client_id,
          parameters: snapshot.parameters,
          dpop_jkt: snapshot.dpop_jkt,
          expires_at: snapshot.expires_at
        })

        pair
      end)

    supervisor = start_supervised!(Task.Supervisor)

    results =
      Task.Supervisor.async_stream_nolink(
        supervisor,
        1..4,
        fn _ ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            decide(%{c | pair: pair}, uri, {:approve, "atproto"})
          end)
        end,
        max_concurrency: 4,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)
    assert Enum.count(results, &(&1 == {:error, :invalid_request_uri})) == 3
  end

  test "confidential key removal or replacement prevents approval and retained binding is copied",
       c do
    signing = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, public} = JOSE.JWK.to_public_map(signing)

    metadata =
      Map.merge(c.metadata, %{
        "token_endpoint_auth_method" => "private_key_jwt",
        "jwks" => %{"keys" => [Map.put(public, "kid", "original")]}
      })

    now = System.system_time(:second)

    assertion =
      JOSE.JWT.sign(signing, %{"alg" => "ES256", "kid" => "original"}, %{
        "iss" => @id,
        "sub" => @id,
        "aud" => @issuer,
        "iat" => now,
        "exp" => now + 120,
        "jti" => random()
      })
      |> JOSE.JWS.compact()
      |> elem(1)

    c =
      Map.merge(c, %{
        opts: Keyword.merge(c.opts, transport(metadata)),
        assertion_params: %{
          "client_assertion" => assertion,
          "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        }
      })

    uri = pushed(c)
    {_, replacement} = JOSE.JWK.generate_key({:ec, :secp256r1}) |> JOSE.JWK.to_public_map()

    for kid <- ["original", "other"] do
      changed = Map.put(metadata, "jwks", %{"keys" => [Map.put(replacement, "kid", kid)]})

      assert {:error, :invalid_client} =
               decide(
                 %{c | opts: Keyword.merge(c.opts, transport(changed))},
                 uri,
                 {:approve, "atproto"}
               )
    end

    assert {:ok, _} = decide(c, uri, {:approve, "atproto"})

    assert Repo.one!(AuthorizationCode).client_binding == %{
             "kid" => "original",
             "alg" => "ES256",
             "jkt" => JOSE.JWK.thumbprint(signing)
           }
  end

  defp decide(c, uri, decision),
    do: AuthorizationCodes.decide(c.pair.access_jwt, @id, uri, decision, c.opts)

  defp transport(doc),
    do: [
      request: Req.new(plug: fn conn -> Req.Test.json(conn, doc) end),
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end
    ]

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp pushed(c) do
    params = %{
      "client_id" => @id,
      "response_type" => "code",
      "redirect_uri" => "https://app.example.com/callback",
      "scope" => "atproto transition:generic transition:email",
      "state" => "state",
      "code_challenge_method" => "S256",
      "code_challenge" => random()
    }

    params = Map.merge(params, Map.get(c, :assertion_params, %{}))
    {_, public} = JOSE.JWK.to_public_map(c.key)

    proof =
      JOSE.JWT.sign(c.key, %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public}, %{
        "jti" => random(),
        "iat" => System.system_time(:second),
        "nonce" => c.nonce,
        "htm" => "POST",
        "htu" => @issuer <> "/oauth/par"
      })
      |> JOSE.JWS.compact()
      |> elem(1)

    {:ok, %{request_uri: uri}} = PAR.push(params, [proof], c.opts)
    uri
  end
end
