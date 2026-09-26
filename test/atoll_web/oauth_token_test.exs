defmodule AtollWeb.OAuthTokenTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.OAuth.{Nonce, PAR, AuthorizationCodes, Session, AccessToken}
  alias Atoll.{Repo, Repositories, SigningKey}
  alias Atoll.Accounts.Sessions
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
      "scope" => "atproto",
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
      "scope" => "atproto",
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
        {:approve, "atproto"},
        Keyword.put(
          Application.fetch_env!(:atoll, :oauth_transport_options),
          :session_options,
          session_options
        )
      )

    # Setup deliberately exercises metadata retrieval; assertions below concern HTTP work only.
    assert_received :metadata_fetched
    assert_received :metadata_fetched

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
  end

  test "code exchange returns opaque DPoP tokens with non-cacheable browser responses", c do
    result = send_form(c, URI.encode_query(c.params))
    body = json_response(result, 200)
    assert body["sub"] == c.did
    assert body["scope"] == "atproto"
    assert body["token_type"] == "DPoP"
    assert body["expires_in"] == 300
    assert Repo.one!(AccessToken).digest == :crypto.hash(:sha256, body["access_token"])
    assert Repo.one!(Session).refresh_digest == :crypto.hash(:sha256, body["refresh_token"])
    assert get_resp_header(result, "cache-control") == ["no-store"]
    assert get_resp_header(result, "pragma") == ["no-cache"]
    assert get_resp_header(result, "access-control-allow-origin") == ["*"]
    assert get_resp_header(result, "access-control-allow-credentials") == []
    [nonce] = get_resp_header(result, "dpop-nonce")
    assert {:ok, _} = Nonce.verify(nonce, :authorization)
    refute nonce == c.nonce
    assert get_resp_header(result, "access-control-expose-headers") == ["dpop-nonce, retry-after"]

    assert send_form(c, URI.encode_query(c.params)) |> json_response(400) == %{
             "error" => "invalid_grant"
           }

    assert Repo.aggregate(Session, :count) == 0
    assert Repo.aggregate(AccessToken, :count) == 0
  end

  test "nonce challenge precedes metadata lookup and leaves the code redeemable", c do
    result = send_form(%{c | nonce: "unknown"}, URI.encode_query(c.params))
    assert json_response(result, 400) == %{"error" => "use_dpop_nonce"}
    refute_received :metadata_fetched
    assert Repo.aggregate(Session, :count) == 0
    [nonce] = get_resp_header(result, "dpop-nonce")
    assert send_form(%{c | nonce: nonce}, URI.encode_query(c.params)) |> json_response(200)
  end

  test "invalid grants and unsupported grant types have OAuth errors", c do
    assert send_form(c, URI.encode_query(Map.put(c.params, "code_verifier", random())))
           |> json_response(400) == %{"error" => "invalid_grant"}

    for grant <- ["refresh_token", "password", "client_credentials"] do
      assert send_form(c, URI.encode_query(Map.put(c.params, "grant_type", grant)))
             |> json_response(400) == %{"error" => "unsupported_grant_type"}
    end

    assert send_form(c, URI.encode_query(Map.delete(c.params, "grant_type")))
           |> json_response(400) == %{"error" => "invalid_request"}

    refute_received :metadata_fetched
  end

  test "duplicate and replayed proofs are rejected before any code-reuse revocation", c do
    conn =
      c.conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("dpop", proof(c))

    [signed] = get_req_header(conn, "dpop")
    duplicate = %{conn | req_headers: [{"dpop", signed} | conn.req_headers]}
    body = URI.encode_query(c.params)

    assert post(duplicate, "/oauth/token", body) |> json_response(400) == %{
             "error" => "invalid_dpop_proof"
           }

    refute_received :metadata_fetched
    assert post(conn, "/oauth/token", body) |> json_response(200)

    assert post(conn, "/oauth/token", body) |> json_response(400) == %{
             "error" => "invalid_dpop_proof"
           }

    assert Repo.aggregate(Session, :count) == 1
  end

  test "configuration is required and host headers cannot choose the proof target", c do
    changed = %{
      c
      | conn:
          c.conn
          |> Map.put(:host, "evil.example.com")
          |> put_req_header("x-forwarded-host", "evil.example.com")
    }

    assert send_form(changed, URI.encode_query(c.params)) |> json_response(200)
    Application.delete_env(:atoll, :oauth_nonce_secret)

    assert send_form(c, URI.encode_query(c.params)) |> json_response(503) == %{
             "error" => "temporarily_unavailable"
           }
  end

  test "rejects duplicate decoded fields, nested fields, invalid encodings and oversized forms",
       c do
    body = URI.encode_query(c.params)

    for invalid <- [
          body <> "&code=second",
          body <> "&co%64e=second",
          body <> "&state[x]=nested",
          body <> "&x=%ZZ",
          body <> "&x=%FF",
          body <> "&",
          "missing-equals"
        ] do
      assert send_form(c, invalid) |> json_response(400)
    end

    assert send_form(c, String.duplicate("x", 49_153)) |> json_response(413)

    assert send_form(c, URI.encode_query(Map.put(c.params, "state", String.duplicate("x", 2049))))
           |> json_response(400)

    refute_received :metadata_fetched
  end

  test "rejects query parameters, other media types, encoding, and authorization headers", c do
    body = URI.encode_query(c.params)
    assert send_form(c, body, "/oauth/token?state=override") |> json_response(400)

    for {header, value, status} <- [
          {"content-type", "application/json", 415},
          {"content-type", "application/x-www-form-urlencoded; charset=latin1", 415},
          {"content-encoding", "gzip", 415},
          {"authorization", "Basic arbitrary", 401}
        ] do
      result =
        c.conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header(header, value)
        |> put_req_header("dpop", proof(c))
        |> post("/oauth/token", body)

      assert json_response(result, status)
      assert get_resp_header(result, "dpop-nonce") != []

      if status == 401,
        do: assert(get_resp_header(result, "www-authenticate") == ["Basic realm=\"oauth\""])
    end

    refute_received :metadata_fetched
  end

  test "methods and encoded route spellings cannot bypass the boundary", c do
    for method <- [:get, :put, :delete, :patch, :head] do
      result = Phoenix.ConnTest.dispatch(c.conn, @endpoint, method, "/oauth/token", nil)
      assert result.status == 405
      assert get_resp_header(result, "allow") == ["POST, OPTIONS"]
    end

    assert send_form(c, "_method=DELETE", "/%6fauth/%74oken") |> json_response(400)
    assert send_form(c, URI.encode_query(c.params) <> "&_method=DELETE") |> json_response(400)
    refute_received :metadata_fetched
  end

  test "CORS preflight permits only the token method and headers", c do
    conn =
      c.conn
      |> put_req_header("origin", "https://app.example.com")
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header("access-control-request-headers", "Content-Type, DPoP")

    result = options(conn, "/oauth/token")
    assert response(result, 204) == ""
    assert get_resp_header(result, "access-control-allow-methods") == ["POST"]
    assert get_resp_header(result, "access-control-allow-headers") == ["content-type, dpop"]

    assert conn
           |> put_req_header("access-control-request-headers", "authorization")
           |> options("/oauth/token")
           |> json_response(400)

    assert conn
           |> put_req_header("access-control-request-method", "DELETE")
           |> options("/oauth/token")
           |> json_response(400)
  end

  test "peer budget applies before parsing and cannot be reset with forwarding headers", c do
    for _ <- 1..20 do
      assert :ok = Atoll.Accounts.SessionLimiter.check({:oauth_token, c.conn.remote_ip}, 20)
    end

    result = %{c | conn: put_req_header(c.conn, "x-forwarded-for", "8.8.8.8")} |> send_form("%ZZ")
    assert json_response(result, 429) == %{"error" => "temporarily_unavailable"}
    assert get_resp_header(result, "retry-after") != []
    assert get_resp_header(result, "dpop-nonce") != []
    assert get_resp_header(result, "access-control-allow-origin") == ["*"]
    assert get(c.conn, "/health") |> json_response(200)
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
