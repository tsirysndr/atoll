defmodule AtollWeb.OAuthPARTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.OAuth.{Nonce, PAR, ClientAssertionUse}
  alias Atoll.Repo
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

    secret = :crypto.strong_rand_bytes(32)
    Application.put_env(:atoll, :oauth_nonce_secret, secret)

    metadata = %{
      "client_id" => @id,
      "grant_types" => ["authorization_code"],
      "response_types" => ["code"],
      "scope" => "atproto transition:generic",
      "redirect_uris" => ["https://app.example.com/callback"],
      "dpop_bound_access_tokens" => true
    }

    transport(metadata)
    key = JOSE.JWK.generate_key({:ec, :secp256r1})
    {:ok, nonce} = Nonce.issue(:authorization)
    id = rem(System.unique_integer([:positive]), 65_536)
    conn = %{conn | remote_ip: {10, 79, div(id, 256), rem(id, 256)}}

    params = %{
      "client_id" => @id,
      "response_type" => "code",
      "redirect_uri" => "https://app.example.com/callback",
      "scope" => "atproto transition:generic",
      "state" => "private state",
      "code_challenge_method" => "S256",
      "code_challenge" => random()
    }

    %{conn: conn, metadata: metadata, params: params, key: key, nonce: nonce}
  end

  test "POST returns a bound request, fresh nonce, no-store, and browser CORS", c do
    result = send_form(c, URI.encode_query(c.params))
    assert %{"request_uri" => uri, "expires_in" => 90} = json_response(result, 201)
    assert {:ok, row} = PAR.get(@id, uri)
    assert row.parameters == c.params
    assert row.dpop_jkt == JOSE.JWK.thumbprint(c.key)
    [nonce] = get_resp_header(result, "dpop-nonce")
    assert {:ok, _} = Nonce.verify(nonce, :authorization)
    refute nonce == c.nonce
    assert get_resp_header(result, "cache-control") == ["no-store"]
    assert get_resp_header(result, "access-control-allow-origin") == ["*"]
    assert get_resp_header(result, "access-control-allow-credentials") == []
    assert get_resp_header(result, "access-control-expose-headers") == ["dpop-nonce, retry-after"]
  end

  test "nonce challenge happens before metadata fetch or assertion consumption", c do
    signing = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, public} = JOSE.JWK.to_public_map(signing)

    metadata =
      Map.merge(c.metadata, %{
        "token_endpoint_auth_method" => "private_key_jwt",
        "jwks" => %{"keys" => [Map.put(public, "kid", "key")]}
      })

    transport(metadata)
    now = System.system_time(:second)

    assertion =
      JOSE.JWT.sign(signing, %{"alg" => "ES256", "kid" => "key"}, %{
        "iss" => @id,
        "sub" => @id,
        "aud" => AtollWeb.Endpoint.url(),
        "iat" => now,
        "exp" => now + 120,
        "jti" => random()
      })
      |> JOSE.JWS.compact()
      |> elem(1)

    body =
      URI.encode_query(
        Map.merge(c.params, %{
          "client_assertion" => assertion,
          "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
        })
      )

    result = send_form(%{c | nonce: "unknown"}, body)
    assert json_response(result, 400) == %{"error" => "use_dpop_nonce"}
    refute_received :metadata_fetched
    assert Repo.aggregate(ClientAssertionUse, :count) == 0
    [nonce] = get_resp_header(result, "dpop-nonce")
    assert send_form(%{c | nonce: nonce}, body) |> json_response(201)
    assert_received :metadata_fetched
    assert Repo.aggregate(ClientAssertionUse, :count) == 1
  end

  test "rejects duplicate decoded fields, nested fields, invalid encodings and oversized forms",
       c do
    body = URI.encode_query(c.params)

    for invalid <- [
          body <> "&state=second",
          body <> "&st%61te=second",
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
    assert send_form(c, body, "/oauth/par?state=override") |> json_response(400)

    for {header, value, status} <- [
          {"content-type", "application/json", 415},
          {"content-type", "application/x-www-form-urlencoded; charset=latin1", 415},
          {"content-encoding", "gzip", 415},
          {"authorization", "Basic arbitrary", 400}
        ] do
      result =
        c.conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> put_req_header(header, value)
        |> put_req_header("dpop", proof(c))
        |> post("/oauth/par", body)

      assert json_response(result, status)
      assert get_resp_header(result, "dpop-nonce") != []
    end

    refute_received :metadata_fetched
  end

  test "methods and encoded route spellings cannot bypass the boundary", c do
    for method <- [:get, :put, :delete, :patch, :head] do
      result = Phoenix.ConnTest.dispatch(c.conn, @endpoint, method, "/oauth/par", nil)
      assert result.status == 405
      assert get_resp_header(result, "allow") == ["POST, OPTIONS"]
    end

    assert send_form(c, "_method=DELETE", "/%6fauth/%70ar") |> json_response(400)
    assert send_form(c, URI.encode_query(c.params) <> "&_method=DELETE") |> json_response(400)
    refute_received :metadata_fetched
  end

  test "CORS preflight permits only the PAR method and headers", c do
    conn =
      c.conn
      |> put_req_header("origin", "https://app.example.com")
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header("access-control-request-headers", "Content-Type, DPoP")

    result = options(conn, "/oauth/par")
    assert response(result, 204) == ""
    assert get_resp_header(result, "access-control-allow-methods") == ["POST"]
    assert get_resp_header(result, "access-control-allow-headers") == ["content-type, dpop"]

    assert conn
           |> put_req_header("access-control-request-headers", "authorization")
           |> options("/oauth/par")
           |> json_response(400)

    assert conn
           |> put_req_header("access-control-request-method", "DELETE")
           |> options("/oauth/par")
           |> json_response(400)
  end

  test "peer budget applies before parsing and cannot be reset with forwarding headers", c do
    for _ <- 1..20 do
      assert :ok = Atoll.Accounts.SessionLimiter.check({:oauth_par, c.conn.remote_ip}, 20)
    end

    result = %{c | conn: put_req_header(c.conn, "x-forwarded-for", "8.8.8.8")} |> send_form("%ZZ")
    assert json_response(result, 429) == %{"error" => "temporarily_unavailable"}
    assert get_resp_header(result, "retry-after") != []
    assert get_resp_header(result, "dpop-nonce") != []
    assert get_resp_header(result, "access-control-allow-origin") == ["*"]
    assert get(c.conn, "/health") |> json_response(200)
  end

  test "missing configuration fails closed and proofs bind the configured URL", c do
    c = %{
      c
      | conn:
          c.conn
          |> Map.put(:host, "evil.example.com")
          |> put_req_header("x-forwarded-host", "evil.example.com")
    }

    assert send_form(c, URI.encode_query(c.params)) |> json_response(201)
    Application.delete_env(:atoll, :oauth_nonce_secret)

    assert send_form(c, URI.encode_query(c.params)) |> json_response(503) == %{
             "error" => "temporarily_unavailable"
           }
  end

  test "duplicate DPoP headers and replay failures use OAuth errors", c do
    body = URI.encode_query(c.params)
    signed = proof(c)

    conn =
      c.conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("dpop", signed)

    duplicate = %{conn | req_headers: [{"dpop", signed} | conn.req_headers]}

    assert post(duplicate, "/oauth/par", body) |> json_response(400) == %{
             "error" => "invalid_dpop_proof"
           }

    refute_received :metadata_fetched
    assert post(conn, "/oauth/par", body) |> json_response(201)

    retry =
      post(conn, "/oauth/par", URI.encode_query(Map.put(c.params, "code_challenge", random())))

    assert json_response(retry, 400) == %{"error" => "invalid_dpop_proof"}
    assert get_resp_header(retry, "dpop-nonce") != []
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

  defp send_form(c, body, path \\ "/oauth/par"),
    do:
      c.conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("dpop", proof(c))
      |> post(path, body)

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp proof(c) do
    {_, public} = JOSE.JWK.to_public_map(c.key)

    JOSE.JWT.sign(c.key, %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public}, %{
      "jti" => random(),
      "iat" => System.system_time(:second),
      "nonce" => c.nonce,
      "htm" => "POST",
      "htu" => AtollWeb.Endpoint.url() <> "/oauth/par"
    })
    |> JOSE.JWS.compact()
    |> elem(1)
  end
end
