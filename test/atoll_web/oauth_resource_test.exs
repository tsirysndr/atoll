defmodule AtollWeb.OAuthResourceTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.OAuth.{Nonce, PAR, AuthorizationCodes, Session, AccessToken, Resource}
  alias Atoll.{Repo, Repositories}
  alias Atoll.Accounts.Sessions
  @path "/xrpc/com.atproto.server.getSession"
  @id "https://app.example.com/metadata.json"

  setup %{conn: conn} do
    for name <- [:oauth_nonce_secret, :oauth_transport_options, :key_encryption_key] do
      prior = Application.fetch_env(:atoll, name)

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end)
    end

    Application.put_env(:atoll, :oauth_nonce_secret, :crypto.strong_rand_bytes(32))

    metadata = %{
      "client_id" => @id,
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "scope" => "atproto transition:generic transition:email",
      "redirect_uris" => ["https://app.example.com/callback"],
      "dpop_bound_access_tokens" => true
    }

    transport(metadata)
    {:ok, nonce} = Nonce.issue(:authorization)
    id = rem(System.unique_integer([:positive]), 65_536)

    c = %{
      conn: %{conn | remote_ip: {10, 80, div(id, 256), rem(id, 256)}},
      key: JOSE.JWK.generate_key({:ec, :secp256r1}),
      nonce: nonce,
      metadata: metadata
    }

    verifier = random()

    params = %{
      "client_id" => @id,
      "response_type" => "code",
      "redirect_uri" => "https://app.example.com/callback",
      "scope" => "atproto transition:generic transition:email",
      "state" => "private-state",
      "code_challenge_method" => "S256",
      "code_challenge" => :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    }

    did = "did:plc:httptoken"
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    {:ok, _} = Repositories.create_managed(did)
    session_options = [secret: :crypto.strong_rand_bytes(32), audience: "did:web:pds.example.com"]
    {:ok, pair} = Sessions.create_for_account(did, session_options)

    {:ok, %{request_uri: uri}} =
      PAR.push(
        params,
        [proof(c, "/oauth/par")],
        Keyword.put(
          Application.fetch_env!(:atoll, :oauth_transport_options),
          :session_options,
          session_options
        )
      )

    {:ok, approved} =
      AuthorizationCodes.decide(
        pair.access_jwt,
        @id,
        uri,
        {:approve, "atproto transition:generic transition:email"},
        Keyword.put(
          Application.fetch_env!(:atoll, :oauth_transport_options),
          :session_options,
          session_options
        )
      )

    # Setup deliberately exercises metadata retrieval; assertions below concern HTTP work only.
    assert_received :metadata_fetched
    assert_received :metadata_fetched

    c =
      Map.merge(c, %{
        did: did,
        params: %{
          "grant_type" => "authorization_code",
          "client_id" => @id,
          "code" => approved.code,
          "redirect_uri" => params["redirect_uri"],
          "code_verifier" => verifier
        }
      })

    tokens = send_form(c, URI.encode_query(c.params)) |> json_response(200)

    Repo.insert!(%Atoll.Accounts.Profile{
      did: did,
      handle: "account.example.com",
      email: "private@example.com",
      email_confirmed_at: DateTime.utc_now(),
      email_auth_factor: true
    })

    {:ok, resource_nonce} = Nonce.issue(:resource)

    Map.merge(c, %{
      tokens: tokens,
      resource_nonce: resource_nonce,
      owner_pair: pair,
      owner_opts: session_options
    })
  end

  test "DPoP getSession exposes identity and only the authorized email fields", c do
    result = read_session(c)
    body = json_response(result, 200)
    assert body["did"] == c.did
    assert body["active"] == true
    assert body["handle"] == "account.example.com"
    assert body["email"] == "private@example.com"
    assert body["emailConfirmed"] == true
    refute Map.has_key?(body, "emailAuthFactor")
    refute Map.has_key?(body, "accessJwt")
    [nonce] = get_resp_header(result, "dpop-nonce")
    assert {:ok, _} = Nonce.verify(nonce, :resource)
    assert {:error, :use_dpop_nonce} = Nonce.verify(nonce, :authorization)
    assert get_resp_header(result, "cache-control") == ["no-store"]
    assert get_resp_header(result, "pragma") == ["no-cache"]
    assert get_resp_header(result, "access-control-allow-origin") == ["*"]
    assert get_resp_header(result, "access-control-allow-credentials") == []
    assert get_resp_header(result, "access-control-expose-headers") |> hd() =~ "dpop-nonce"
  end

  test "narrowed access tokens cannot regain email from the broader session", c do
    params = %{
      "grant_type" => "refresh_token",
      "client_id" => @id,
      "refresh_token" => c.tokens["refresh_token"],
      "scope" => "atproto"
    }

    narrowed = send_form(c, URI.encode_query(params)) |> json_response(200)
    body = read_session(%{c | tokens: narrowed}) |> json_response(200)
    refute Map.has_key?(body, "email")
    refute Map.has_key?(body, "emailConfirmed")
    refute Map.has_key?(body, "emailAuthFactor")
    assert body["did"] == c.did
    assert Repo.one!(Session).scope =~ "transition:email"
    assert read_session(c) |> json_response(200) |> Map.has_key?("email")
  end

  test "resource nonce challenge is distinct from authorization server nonce", c do
    result = read_session(%{c | resource_nonce: c.nonce})
    assert json_response(result, 401) == %{"error" => "use_dpop_nonce"}

    assert get_resp_header(result, "www-authenticate") == [
             "DPoP error=\"use_dpop_nonce\", algs=\"ES256\""
           ]

    [nonce] = get_resp_header(result, "dpop-nonce")
    assert read_session(%{c | resource_nonce: nonce}) |> json_response(200)
  end

  test "method, target, key, access hash, missing proof and replays are rejected", c do
    token = c.tokens["access_token"]

    for changes <- [
          %{"htm" => "POST"},
          %{"htu" => AtollWeb.Endpoint.url() <> "/other"},
          %{"ath" => "wrong"}
        ] do
      result = request(c, token, resource_proof(c, token, changes))
      assert json_response(result, 401) == %{"error" => "invalid_dpop_proof"}
    end

    other = %{c | key: JOSE.JWK.generate_key({:ec, :secp256r1})}
    assert request(c, token, resource_proof(other, token)) |> json_response(401)
    conn = put_req_header(c.conn, "authorization", "DPoP " <> token)
    assert get(conn, @path) |> json_response(401) == %{"error" => "invalid_dpop_proof"}
    signed = resource_proof(c, token)
    assert request(c, token, signed) |> json_response(200)
    assert request(c, token, signed) |> json_response(401) == %{"error" => "invalid_dpop_proof"}
  end

  test "revocation, expiry, and inactive accounts invalidate access", c do
    token = Repo.get!(AccessToken, :crypto.hash(:sha256, c.tokens["access_token"]))
    token |> Ecto.Changeset.change(expires_at: 1) |> Repo.update!()
    assert read_session(c) |> json_response(401) == %{"error" => "invalid_token"}

    Repo.get!(AccessToken, token.digest)
    |> Ecto.Changeset.change(expires_at: token.expires_at)
    |> Repo.update!()

    Repo.get!(Atoll.Repositories.Head, c.did)
    |> Ecto.Changeset.change(status: :deactivated)
    |> Repo.update!()

    assert read_session(c) |> json_response(401) == %{"error" => "invalid_token"}

    Repo.get!(Atoll.Repositories.Head, c.did)
    |> Ecto.Changeset.change(status: :active)
    |> Repo.update!()

    assert read_session(c) |> json_response(200)
    Repo.delete_all(Atoll.Accounts.Session)
    assert read_session(c) |> json_response(401) == %{"error" => "invalid_token"}
  end

  test "opaque access tokens cannot be downgraded to Bearer or used for account management", c do
    token = c.tokens["access_token"]
    conn = put_req_header(c.conn, "authorization", "Bearer " <> token)
    assert get(conn, @path) |> json_response(401) == %{"error" => "invalid_token"}
    conn = put_req_header(c.conn, "authorization", "DPoP " <> token)
    duplicate = %{conn | req_headers: [{"authorization", "Bearer " <> token} | conn.req_headers]}
    assert get(duplicate, @path) |> json_response(400) == %{"error" => "invalid_request"}
    assert get(conn, "/xrpc/com.atproto.server.listAppPasswords").status == 401
  end

  test "session expiry, source expiry, issuer mismatch and refresh tokens cannot authorize reads",
       c do
    session = Repo.one!(Session)

    for changes <- [%{expires_at: 1}, %{issuer: "https://other.example.com"}] do
      Repo.get!(Session, session.id) |> Ecto.Changeset.change(changes) |> Repo.update!()
      assert read_session(c) |> json_response(401) == %{"error" => "invalid_token"}

      Repo.get!(Session, session.id)
      |> Ecto.Changeset.change(expires_at: session.expires_at, issuer: session.issuer)
      |> Repo.update!()
    end

    assert read_session(%{
             c
             | tokens: Map.put(c.tokens, "access_token", c.tokens["refresh_token"])
           })
           |> json_response(401) == %{"error" => "invalid_token"}

    Repo.one!(Atoll.Accounts.Session) |> Ecto.Changeset.change(expires_at: 1) |> Repo.update!()
    assert read_session(c) |> json_response(401) == %{"error" => "invalid_token"}
  end

  test "scope checks and rolled-back readers cannot restore an admitted proof", c do
    token = c.tokens["access_token"]
    opts = [required_scopes: ["transition:chat.bsky"]]

    assert {:error, :insufficient_scope} =
             Resource.read(
               token,
               [resource_proof(c, token)],
               AtollWeb.Endpoint.url() <> @path,
               fn _ -> flunk("unauthorized callback") end,
               opts
             )

    signed = resource_proof(c, token)

    assert {:error, :reader_failure} =
             Resource.read(token, [signed], AtollWeb.Endpoint.url() <> @path, fn _ ->
               Repo.rollback(:reader_failure)
             end)

    assert {:error, :dpop_replayed} =
             Resource.read(token, [signed], AtollWeb.Endpoint.url() <> @path, fn _ -> :ok end)

    assert {:ok, {:error, :oauth_resource_inside_transaction}} =
             Repo.transaction(fn ->
               Resource.read(
                 token,
                 [resource_proof(c, token)],
                 AtollWeb.Endpoint.url() <> @path,
                 fn _ -> :ok end
               )
             end)
  end

  test "CORS allows DPoP and errors before the controller still include a nonce", c do
    conn =
      c.conn
      |> put_req_header("origin", "https://app.example.com")
      |> put_req_header("access-control-request-method", "GET")
      |> put_req_header("access-control-request-headers", "authorization,dpop")

    assert options(conn, @path).status == 204
    conn = put_req_header(c.conn, "authorization", "DPoP " <> c.tokens["access_token"])

    for _ <- 1..300,
        do: assert(:ok = Atoll.Accounts.SessionLimiter.check({:session, conn.remote_ip}, 300))

    result = get(conn, @path)
    assert result.status == 429
    assert get_resp_header(result, "dpop-nonce") != []
    assert get_resp_header(result, "access-control-expose-headers") |> hd() =~ "dpop-nonce"
  end

  test "proof target uses configured origin and configuration failures close access", c do
    conn =
      %{c.conn | host: "evil.example.com"}
      |> put_req_header("x-forwarded-host", "evil.example.com")

    assert read_session(%{c | conn: conn}) |> json_response(200)
    Application.delete_env(:atoll, :oauth_nonce_secret)
    assert read_session(c) |> json_response(503) == %{"error" => "temporarily_unavailable"}
  end

  test "OAuth service tokens are account-signed, audience-bound and method-bound", c do
    params = %{
      "aud" => "did:web:appview.example.com#bsky_appview",
      "lxm" => "app.bsky.feed.getTimeline",
      "exp" => Integer.to_string(System.system_time(:second) + 1800)
    }

    response = service_auth(c, params)
    %{"token" => token} = json_response(response, 200)
    claims = verify_service(token, c.did)
    assert claims["iss"] == c.did
    assert claims["aud"] == params["aud"]
    assert claims["lxm"] == params["lxm"]
    assert claims["exp"] == String.to_integer(params["exp"])
    assert get_resp_header(response, "dpop-nonce") != []
    assert get_resp_header(response, "cache-control") == ["no-store"]
    %{"token" => another} = service_auth(c, Map.take(params, ["aud"])) |> json_response(200)
    second = verify_service(another, c.did)
    refute Map.has_key?(second, "lxm")
    assert second["exp"] - second["iat"] == 60
    refute second["jti"] == claims["jti"]

    assert {:error, :invalid_token} =
             Sessions.authenticate(token,
               secret: :crypto.strong_rand_bytes(32),
               audience: "did:web:pds.example.com"
             )
  end

  test "service delegation requires current generic scope and separate chat permission", c do
    params = %{"aud" => "did:web:chat.example.com", "lxm" => "chat.bsky.convo.listConvos"}
    assert service_auth(c, params) |> json_response(403) == %{"error" => "insufficient_scope"}
    assert service_auth(c, %{params | "lxm" => "CHAT.BSKY.CONVO.LISTCONVOS"}).status == 403
    broad = "atproto transition:generic transition:chat.bsky transition:email"
    Repo.update_all(Session, set: [scope: broad])
    Repo.update_all(AccessToken, set: [scope: broad])
    assert service_auth(c, params) |> json_response(200)
    Repo.update_all(AccessToken, set: [scope: "atproto transition:generic"])
    assert service_auth(c, params).status == 403
    Repo.update_all(AccessToken, set: [scope: "atproto transition:email"])

    assert service_auth(c, %{params | "lxm" => "app.bsky.feed.getTimeline"})
           |> json_response(403) == %{"error" => "insufficient_scope"}
  end

  test "service parameter and custody errors keep XRPC errors and consume proofs", c do
    params = %{"aud" => "did:web:service.example.com"}

    for changes <- [
          %{"aud" => "not-a-did"},
          %{"lxm" => "com.atproto.identity.signPlcOperation"},
          %{"lxm" => "com.atproto.server.getSession"}
        ] do
      assert %{"error" => "InvalidRequest"} =
               service_auth(c, Map.merge(params, changes)) |> json_response(400)
    end

    assert service_auth(c, Map.put(params, "lxm", "com.atproto.server.createAccount"))
           |> json_response(403) == %{"error" => "insufficient_scope"}

    signed = service_proof(c)

    assert %{"error" => "BadExpiration"} =
             service_auth(c, Map.put(params, "exp", "1"), signed) |> json_response(400)

    assert service_auth(c, params, signed) |> json_response(401) ==
             %{"error" => "invalid_dpop_proof"}

    Application.delete_env(:atoll, :key_encryption_key)
    assert %{"error" => "ServiceUnavailable"} = service_auth(c, params) |> json_response(503)
  end

  test "service issuance rejects revoked sessions, inactive accounts and wrong proof targets",
       c do
    params = %{"aud" => "did:web:service.example.com"}

    assert service_auth(c, params, resource_proof(c, c.tokens["access_token"]))
           |> json_response(401) == %{"error" => "invalid_dpop_proof"}

    Repo.get!(Atoll.Repositories.Head, c.did)
    |> Ecto.Changeset.change(status: :deactivated)
    |> Repo.update!()

    assert service_auth(c, params).status == 401

    Repo.get!(Atoll.Repositories.Head, c.did)
    |> Ecto.Changeset.change(status: :active)
    |> Repo.update!()

    Repo.delete_all(Session)
    assert service_auth(c, params) |> json_response(401) == %{"error" => "invalid_token"}
  end

  test "DPoP clients export public repositories and referenced blobs with identity-only scope",
       c do
    Repo.update_all(AccessToken, set: [scope: "atproto"])
    bytes = "public media"
    {:ok, blob} = Atoll.Blobs.stage(c.did, bytes, "text/plain")
    cid = blob["ref"]["$link"]

    assert export_request(c, "listBlobs", %{"did" => c.did}) |> json_response(200) == %{
             "cids" => []
           }

    assert export_request(c, "getBlob", %{"did" => c.did, "cid" => cid}).status == 400
    {:ok, key} = Atoll.KeyVault.fetch(c.did)
    record = %{"$type" => "com.example.record", "blob" => blob}
    {:ok, _} = Repositories.apply_writes(c.did, [{:put, "com.example.record/media", record}], key)

    assert export_request(c, "listBlobs", %{"did" => c.did}) |> json_response(200) == %{
             "cids" => [cid]
           }

    response = export_request(c, "getBlob", %{"did" => c.did, "cid" => cid})
    assert response(response, 200) == bytes
    assert get_resp_header(response, "dpop-nonce") != []
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
    repo = export_request(c, "getRepo", %{"did" => c.did})
    {:ok, head} = Repositories.get_head(c.did)
    assert {:ok, %{roots: [root]}} = Atoll.CAR.decode(response(repo, 200))
    assert root == head.head
  end

  test "export proofs cannot be replayed, retargeted or downgraded to Bearer", c do
    params = %{"did" => c.did}
    signed = export_proof(c, "listBlobs")
    assert export_request(c, "listBlobs", params, signed).status == 200

    assert export_request(c, "listBlobs", params, signed) |> json_response(401) ==
             %{"error" => "invalid_dpop_proof"}

    assert export_request(c, "getRepo", params, export_proof(c, "listBlobs")).status == 401

    assert c.conn
           |> put_req_header("authorization", "Bearer " <> c.tokens["access_token"])
           |> get("/xrpc/com.atproto.sync.getRepo", params)
           |> json_response(401) ==
             %{"error" => "invalid_token"}

    # A missing blob still consumes an admitted proof.
    params = Map.put(params, "cid", Atoll.CID.create("absent", :raw) |> Atoll.CID.to_base32())
    signed = export_proof(c, "getBlob")
    assert export_request(c, "getBlob", params, signed).status == 400
    assert export_request(c, "getBlob", params, signed).status == 401
    Repo.delete_all(Session)

    assert export_request(c, "getRepo", Map.take(params, ["did"])) |> json_response(401) == %{
             "error" => "invalid_token"
           }
  end

  test "OAuth export credentials never unlock inactive or unreferenced data", c do
    other = "did:plc:otherexport"
    {:ok, _} = Repositories.create_managed(other)
    {:ok, blob} = Atoll.Blobs.stage(other, "staged", "text/plain")
    assert export_request(c, "getRepo", %{"did" => other}).status == 200

    assert export_request(c, "getBlob", %{"did" => other, "cid" => blob["ref"]["$link"]}).status ==
             400

    {:ok, _} = Repositories.set_status(other, :deactivated)

    for method <- ["getRepo", "listBlobs", "getBlob"] do
      params =
        if method == "getBlob",
          do: %{"did" => other, "cid" => blob["ref"]["$link"]},
          else: %{"did" => other}

      assert export_request(c, method, params).status == 400
    end

    {:ok, _} = Repositories.set_status(c.did, :deactivated)

    for method <- ["getRepo", "listBlobs", "getBlob"] do
      params =
        if method == "getBlob",
          do: %{"did" => c.did, "cid" => blob["ref"]["$link"]},
          else: %{"did" => c.did}

      assert export_request(c, method, params)
             |> json_response(401) == %{"error" => "invalid_token"}
    end
  end

  test "owner session management revokes an exchanged grant and its refresh access", c do
    assert read_session(c).status == 200

    assert {:ok, %{sessions: [%{id: id}]}} =
             Atoll.OAuth.SessionManagement.list(c.owner_pair.access_jwt, 50, nil, c.owner_opts)

    assert {:ok, :ok} =
             Atoll.OAuth.SessionManagement.revoke(c.owner_pair.access_jwt, id, c.owner_opts)

    assert read_session(c) |> json_response(401) == %{"error" => "invalid_token"}

    params = %{
      "grant_type" => "refresh_token",
      "client_id" => @id,
      "refresh_token" => c.tokens["refresh_token"]
    }

    assert send_form(c, URI.encode_query(params)) |> json_response(400) == %{
             "error" => "invalid_grant"
           }

    assert {:ok, _} = Sessions.authenticate(c.owner_pair.access_jwt, c.owner_opts)
  end

  defp export_request(c, method, params, signed \\ nil),
    do:
      c.conn
      |> put_req_header("authorization", "DPoP " <> c.tokens["access_token"])
      |> put_req_header("dpop", signed || export_proof(c, method))
      |> get("/xrpc/com.atproto.sync." <> method, params)

  defp export_proof(c, method),
    do:
      resource_proof(c, c.tokens["access_token"], %{
        "htu" => AtollWeb.Endpoint.url() <> "/xrpc/com.atproto.sync." <> method
      })

  defp service_auth(c, params, signed \\ nil),
    do:
      c.conn
      |> put_req_header("authorization", "DPoP " <> c.tokens["access_token"])
      |> put_req_header("dpop", signed || service_proof(c))
      |> get("/xrpc/com.atproto.server.getServiceAuth", params)

  defp service_proof(c),
    do:
      resource_proof(c, c.tokens["access_token"], %{
        "htu" => AtollWeb.Endpoint.url() <> "/xrpc/com.atproto.server.getServiceAuth"
      })

  defp verify_service(token, did) do
    {:ok, key} = Atoll.KeyVault.fetch(did)
    [header, claims, signature] = String.split(token, ".")
    <<r::unsigned-big-256, s::unsigned-big-256>> = Base.url_decode64!(signature, padding: false)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    curve = if key.curve == :k256, do: :secp256k1, else: :secp256r1
    assert :crypto.verify(:ecdsa, :sha256, header <> "." <> claims, der, [key.public, curve])
    claims |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp read_session(c),
    do: request(c, c.tokens["access_token"], resource_proof(c, c.tokens["access_token"]))

  defp request(c, token, proof),
    do:
      c.conn
      |> put_req_header("authorization", "DPoP " <> token)
      |> put_req_header("dpop", proof)
      |> get(@path)

  defp resource_proof(c, token, changes \\ %{}) do
    {_, public} = JOSE.JWK.to_public_map(c.key)

    claims =
      %{
        "jti" => random(),
        "iat" => System.system_time(:second),
        "nonce" => c.resource_nonce,
        "htm" => "GET",
        "htu" => AtollWeb.Endpoint.url() <> @path,
        "ath" => :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)
      }
      |> Map.merge(changes)

    JOSE.JWT.sign(c.key, %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp transport(metadata) do
    parent = self()

    Application.put_env(:atoll, :oauth_transport_options,
      request:
        Req.new(
          plug: fn conn ->
            send(parent, :metadata_fetched)
            Req.Test.json(conn, metadata)
          end
        ),
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end
    )
  end

  defp send_form(c, body, path \\ "/oauth/token"),
    do:
      c.conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("dpop", proof(c))
      |> post(path, body)

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp proof(c, path \\ "/oauth/token") do
    {_, public} = JOSE.JWK.to_public_map(c.key)

    JOSE.JWT.sign(c.key, %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public}, %{
      "jti" => random(),
      "iat" => System.system_time(:second),
      "nonce" => c.nonce,
      "htm" => "POST",
      "htu" => AtollWeb.Endpoint.url() <> path
    })
    |> JOSE.JWS.compact()
    |> elem(1)
  end
end
