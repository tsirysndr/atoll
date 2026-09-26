defmodule Atoll.OAuth.PARTest do
  use Atoll.DataCase, async: false
  alias Atoll.OAuth.{PAR, Nonce, PushedRequest, PKCEUse, ProofUse}
  @issuer "https://pds.example.com"
  @id "https://app.example.com/metadata.json"

  setup do
    metadata = %{
      "client_id" => @id,
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "scope" => "atproto transition:generic transition:email transition:chat.bsky",
      "redirect_uris" => ["https://app.example.com/callback"],
      "dpop_bound_access_tokens" => true
    }

    secret = :crypto.strong_rand_bytes(32)
    opts = [issuer: @issuer, secret: secret] ++ transport(metadata)
    {:ok, nonce} = Nonce.issue(:authorization, opts)
    key = JOSE.JWK.generate_key({:ec, :secp256r1})

    params = %{
      "client_id" => @id,
      "response_type" => "code",
      "redirect_uri" => "https://app.example.com/callback",
      "scope" => "atproto",
      "state" => "client-state",
      "code_challenge_method" => "S256",
      "code_challenge" => challenge(),
      "login_hint" => "alice.example.com"
    }

    %{metadata: metadata, opts: opts, nonce: nonce, key: key, params: params}
  end

  test "persists an opaque request with exact parameters and DPoP binding", c do
    assert {:ok, result} = push(c)
    assert result.expires_in == 90
    assert String.starts_with?(result.request_uri, "urn:ietf:params:oauth:request_uri:")
    assert {:ok, row} = PAR.get(@id, result.request_uri, c.opts)
    assert row.parameters == c.params
    assert row.dpop_jkt == JOSE.JWK.thumbprint(c.key)
    assert row.client_binding == nil
    assert row.digest == :crypto.hash(:sha256, result.request_uri)
    assert Repo.aggregate(PKCEUse, :count) == 1
    assert Repo.one!(PKCEUse).expires_at - row.expires_at == 86_310
    refute inspect(row) =~ "client-state"

    assert {:error, :invalid_request_uri} =
             PAR.get("https://other.example.com/meta", result.request_uri, c.opts)

    assert {:error, :invalid_request_uri} =
             PAR.get(@id, result.request_uri, issuer: "https://other.example.com")

    assert {:error, :invalid_request_uri} = PAR.get(nil, result.request_uri, c.opts)
    assert {:error, :invalid_request_uri} = PAR.get(@id, result.request_uri <> "=", c.opts)
    assert {:ok, other} = push(%{c | params: Map.put(c.params, "code_challenge", challenge())})
    refute other.request_uri == result.request_uri
  end

  test "expiry of request does not release its 24-hour challenge reservation", c do
    assert {:ok, result} = push(c)
    Repo.one!(PushedRequest) |> Ecto.Changeset.change(expires_at: 1) |> Repo.update!()
    assert {:error, :invalid_request_uri} = PAR.get(@id, result.request_uri, c.opts)
    assert {:error, :pkce_challenge_reused} = push(c)
    # The same challenge is also rejected for another client of this issuer.
    id = "https://other.example.com/metadata.json"
    metadata = Map.put(c.metadata, "client_id", id)

    changed = %{
      c
      | params: Map.put(c.params, "client_id", id),
        opts: Keyword.merge(c.opts, transport(metadata))
    }

    assert {:error, :pkce_challenge_reused} = push(changed)
    Repo.one!(PKCEUse) |> Ecto.Changeset.change(expires_at: 1) |> Repo.update!()
    assert {:ok, _} = push(c)
    assert Repo.aggregate(PushedRequest, :count) == 1
    assert Repo.aggregate(PKCEUse, :count) == 1
  end

  test "invalid parameters, redirect changes, and unsupported scopes create no request", c do
    for changes <- [
          %{"state" => ""},
          %{"response_type" => "token"},
          %{"code_challenge_method" => "plain"},
          %{"code_challenge" => "invalid"},
          %{"scope" => ["atproto"]},
          %{"client_secret" => "bad"},
          %{"code_verifier" => "secret"},
          %{"request_uri" => "external"},
          %{"login_hint" => "a\nb"}
        ] do
      options = Keyword.put(c.opts, :lookup, fn _ -> flunk("unexpected network") end)

      assert {:error, :invalid_request} =
               push(%{c | params: Map.merge(c.params, changes), opts: options})
    end

    for {changes, error} <- [
          {%{"redirect_uri" => "https://evil.example.com/callback"}, :invalid_redirect_uri},
          {%{"scope" => "atproto undeclared"}, :invalid_scope},
          {%{"scope" => "atproto transition:chat.bsky"}, :invalid_scope}
        ] do
      assert {:error, ^error} = push(%{c | params: Map.merge(c.params, changes)})
    end

    assert Repo.aggregate(PushedRequest, :count) == 0
    assert Repo.aggregate(PKCEUse, :count) == 0
    assert Repo.aggregate(ProofUse, :count) == 0
  end

  test "requires nonce, proof signature, and matching optional DPoP key", c do
    assert {:error, :invalid_dpop_proof} = PAR.push(c.params, [], c.opts)
    assert {:error, :use_dpop_nonce} = PAR.push(c.params, [proof(%{c | nonce: "wrong"})], c.opts)

    assert {:error, :invalid_dpop_proof} =
             push(%{c | params: Map.put(c.params, "dpop_jkt", "wrong")})

    assert Repo.aggregate(PushedRequest, :count) == 0
    assert Repo.aggregate(PKCEUse, :count) == 0

    assert {:ok, _} =
             push(%{c | params: Map.put(c.params, "dpop_jkt", JOSE.JWK.thumbprint(c.key))})
  end

  test "confidential clients retain verified key binding but never persist assertion bytes", c do
    signing = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, public} = JOSE.JWK.to_public_map(signing)

    metadata =
      Map.merge(c.metadata, %{
        "token_endpoint_auth_method" => "private_key_jwt",
        "jwks" => %{"keys" => [Map.put(public, "kid", "signing")]}
      })

    c = %{c | opts: Keyword.merge(c.opts, transport(metadata))}
    assert {:error, :invalid_client} = push(c)
    now = System.system_time(:second)

    assertion =
      JOSE.JWT.sign(signing, %{"alg" => "ES256", "kid" => "signing"}, %{
        "iss" => @id,
        "sub" => @id,
        "aud" => @issuer,
        "iat" => now,
        "exp" => now + 120,
        "jti" => "par-assertion"
      })
      |> JOSE.JWS.compact()
      |> elem(1)

    params =
      Map.merge(c.params, %{
        "client_assertion" => assertion,
        "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
      })

    assert {:ok, result} = push(%{c | params: params})
    assert {:ok, row} = PAR.get(@id, result.request_uri, c.opts)
    assert row.parameters == c.params

    assert row.client_binding == %{
             "kid" => "signing",
             "alg" => "ES256",
             "jkt" => JOSE.JWK.thumbprint(signing)
           }

    refute Jason.encode!(row.parameters) =~ assertion
    assert {:error, :client_assertion_replayed} = push(%{c | params: params})
  end

  test "replayed proofs and nested calls cannot reserve new challenges", c do
    proof = proof(c)
    assert {:ok, _} = PAR.push(c.params, [proof], c.opts)

    assert {:error, :dpop_replayed} =
             PAR.push(Map.put(c.params, "code_challenge", challenge()), [proof], c.opts)

    assert {:ok, {:error, :oauth_par_inside_transaction}} = Repo.transaction(fn -> push(c) end)
    assert Repo.aggregate(PKCEUse, :count) == 1
  end

  test "concurrent distinct proofs sharing a challenge admit only one request", c do
    digest =
      :crypto.hash(
        :sha256,
        Atoll.CBOR.encode!(["atoll.oauth.pkce-use.v1", @issuer, c.params["code_challenge"]])
      )

    headers = for _ <- 1..4, do: proof(c)
    # Each committed worker returns its request or error. Cleanup removes only this
    # test's unique challenge/request/proof markers, never other tests' records.
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
        Repo.delete_all(from r in PKCEUse, where: r.digest == ^digest)
        Repo.delete_all(from r in PushedRequest, where: r.dpop_jkt == ^JOSE.JWK.thumbprint(c.key))
        Repo.delete_all(from r in ProofUse, where: r.digest in ^proof_digests)
      end)
    end)

    supervisor = start_supervised!(Task.Supervisor)

    results =
      Task.Supervisor.async_stream_nolink(
        supervisor,
        headers,
        fn header ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            PAR.push(c.params, [header], c.opts)
          end)
        end,
        max_concurrency: 4,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :pkce_challenge_reused})) == 3
  end

  test "request capacity failure does not reserve a challenge", c do
    rows =
      for i <- 1..10_000,
          do: %{
            digest: <<i::256>>,
            issuer: @issuer,
            client_id: @id,
            parameters: c.params,
            dpop_jkt: JOSE.JWK.thumbprint(c.key),
            expires_at: System.system_time(:second) + 300
          }

    for chunk <- Enum.chunk_every(rows, 1000),
        do: Repo.insert_all(PushedRequest, chunk, log: false)

    assert {:error, :oauth_par_store_full} = push(c)
    assert Repo.aggregate(PKCEUse, :count) == 0
    Repo.get!(PushedRequest, <<1::256>>) |> Ecto.Changeset.change(expires_at: 1) |> Repo.update!()
    assert {:ok, _} = push(c)
    assert Repo.aggregate(PushedRequest, :count) == 10_000
    assert Repo.aggregate(PKCEUse, :count) == 1
  end

  test "challenge capacity fails closed and expiry cleanup has a bounded batch", c do
    for chunk <- Enum.chunk_every(1..100_000, 10_000) do
      Repo.insert_all(
        PKCEUse,
        Enum.map(
          chunk,
          &%{digest: <<&1::256>>, expires_at: System.system_time(:second) + 86_400}
        ),
        log: false
      )
    end

    assert {:error, :oauth_par_store_full} = push(c)
    assert Repo.aggregate(PushedRequest, :count) == 0
    Repo.get!(PKCEUse, <<1::256>>) |> Ecto.Changeset.change(expires_at: 1) |> Repo.update!()
    assert {:ok, _} = push(c)
    assert Repo.aggregate(PKCEUse, :count) == 100_000
    Repo.delete_all(PKCEUse)
    Repo.insert_all(PKCEUse, for(i <- 1..1005, do: %{digest: <<i::256>>, expires_at: 1}))
    assert {:ok, _} = push(%{c | params: Map.put(c.params, "code_challenge", challenge())})
    assert Repo.aggregate(PKCEUse, :count) == 6
  end

  defp transport(doc),
    do: [
      request: Req.new(plug: fn conn -> Req.Test.json(conn, doc) end),
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end
    ]

  defp challenge, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp push(c), do: PAR.push(c.params, [proof(c)], c.opts)

  defp proof(c) do
    {_, public} = JOSE.JWK.to_public_map(c.key)

    JOSE.JWT.sign(c.key, %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public}, %{
      "jti" => challenge(),
      "iat" => System.system_time(:second),
      "nonce" => c.nonce,
      "htm" => "POST",
      "htu" => @issuer <> "/oauth/par"
    })
    |> JOSE.JWS.compact()
    |> elem(1)
  end
end
