defmodule AtollWeb.OAuthResourceTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.OAuth.{Nonce, PAR, AuthorizationCodes, Session, AccessToken, Resource}
  alias Atoll.{Repo, Repositories, SigningKey}
  alias Atoll.Accounts.Sessions
  @path "/xrpc/com.atproto.server.getSession"
  @id "https://app.example.com/metadata.json"

  setup %{conn: conn} do
    for name <- [:oauth_nonce_secret, :oauth_transport_options] do
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
    {:ok, _} = Repositories.create(did, SigningKey.generate())
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
    Map.merge(c, %{tokens: tokens, resource_nonce: resource_nonce})
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
