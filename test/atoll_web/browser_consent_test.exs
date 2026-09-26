defmodule AtollWeb.BrowserConsentTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.OAuth.{PAR, Nonce, PushedRequest, AuthorizationCode}
  alias Atoll.Repo
  @redirect_uri "http://127.0.0.1:8750/callback?keep=yes"
  @scope "atproto transition:generic transition:email"
  @client "http://localhost?" <>
            URI.encode_query(%{"scope" => @scope, "redirect_uri" => @redirect_uri})

  setup %{conn: conn} do
    for key <- [:session_signing_key, :key_encryption_key, :oauth_nonce_secret] do
      prior = Application.fetch_env(:atoll, key)
      Application.put_env(:atoll, key, :crypto.strong_rand_bytes(32))

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end)
    end

    did = "did:plc:browserconsent"
    {:ok, _} = Atoll.Repositories.create_managed(did)
    {:ok, _} = Atoll.Accounts.Credentials.create(did, "browser password")
    {:ok, nonce} = Nonce.issue(:authorization)
    key = JOSE.JWK.generate_key({:ec, :secp256r1})
    verifier = random()

    params = %{
      "client_id" => @client,
      "response_type" => "code",
      "redirect_uri" => @redirect_uri,
      "scope" => @scope,
      "state" => "app-state",
      "code_challenge_method" => "S256",
      "code_challenge" => :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false),
      "login_hint" => did
    }

    id = rem(System.unique_integer([:positive]), 65_536)

    c = %{
      conn: %{conn | remote_ip: {10, 98, div(id, 256), rem(id, 256)}},
      key: key,
      nonce: nonce,
      params: params,
      verifier: verifier,
      did: did
    }

    {:ok, %{request_uri: uri}} = PAR.push(params, [proof(c, "/oauth/par")])
    Map.put(c, :uri, uri)
  end

  test "browser consent narrows permissions and exchanges a code; logout revokes its source", c do
    page = consent_page(c)
    assert html_response(page, 200) =~ "Connect an application"
    assert page.resp_body =~ c.did
    assert page.resp_body =~ "Read your email"
    approved = submit(page, %{"decision" => "approve"})
    callback = redirected_to(approved, 303) |> URI.parse()
    params = URI.decode_query(callback.query)
    assert callback.host == "127.0.0.1"
    assert params["keep"] == "yes"
    assert params["state"] == "app-state"
    assert params["iss"] == AtollWeb.Endpoint.url()
    assert is_binary(params["code"])
    assert Repo.aggregate(PushedRequest, :count) == 0
    tokens = exchange(c, params["code"]) |> json_response(200)
    assert tokens["scope"] == "atproto"
    assert tokens["sub"] == c.did
    {:ok, nonce} = Nonce.issue(:resource)

    read_proof =
      proof(%{c | nonce: nonce}, "/xrpc/com.atproto.server.getSession", "GET", %{
        "ath" =>
          :crypto.hash(:sha256, tokens["access_token"]) |> Base.url_encode64(padding: false)
      })

    assert c.conn
           |> put_req_header("authorization", "DPoP " <> tokens["access_token"])
           |> put_req_header("dpop", read_proof)
           |> get("/xrpc/com.atproto.server.getSession")
           |> json_response(200)

    sessions = approved |> browser() |> get("/account/sessions")
    assert sessions.resp_body =~ "Revoke access"
    logout = post_form(sessions, "/account/logout", %{})
    assert redirected_to(logout, 303) == "/account/login"
    assert Repo.aggregate(Atoll.OAuth.Session, :count) == 0
  end

  test "denial returns only the stored callback, state and issuer and consumes the request", c do
    page = consent_page(c)
    denied = submit(page, %{"decision" => "deny"})
    uri = redirected_to(denied, 303) |> URI.parse()

    assert URI.decode_query(uri.query) == %{
             "keep" => "yes",
             "state" => "app-state",
             "iss" => AtollWeb.Endpoint.url(),
             "error" => "access_denied"
           }

    assert Repo.aggregate(AuthorizationCode, :count) == 0
    assert Repo.aggregate(PushedRequest, :count) == 0
    assert submit(page, %{"decision" => "approve"}).status == 400
  end

  test "CSRF, view binding and requested scopes cannot be bypassed", c do
    page = consent_page(c)

    assert page
           |> browser()
           |> put_req_header("content-type", "application/x-www-form-urlencoded")
           |> post(
             "/oauth/authorize",
             URI.encode_query(%{"decision" => "approve", "view" => value(page, "view")})
           )
           |> response(403)

    for changes <- [
          %{"view" => "other"},
          %{"chat" => "yes"},
          %{"redirect_uri" => "https://evil.example.com"}
        ] do
      assert submit(page, Map.merge(%{"decision" => "approve"}, changes)).status == 400
    end

    assert Repo.aggregate(AuthorizationCode, :count) == 0
    assert Repo.aggregate(PushedRequest, :count) == 1
  end

  test "a different login hint cannot grant the current account", c do
    Repo.update_all(PushedRequest,
      set: [parameters: Map.put(c.params, "login_hint", "did:plc:otheraccount")]
    )

    page = consent_page(c)
    assert html_response(page, 400) =~ "different account"
    assert Repo.aggregate(AuthorizationCode, :count) == 0
  end

  test "unknown, expired and duplicate front-channel requests fail locally", c do
    for query <- [
          "client_id=x&request_uri=bad",
          "client_id=x&client_id=y&request_uri=bad",
          URI.encode_query(%{client_id: @client, request_uri: c.uri, redirect_uri: @redirect_uri})
        ] do
      result = get(c.conn, "/oauth/authorize?" <> query)
      assert result.status == 400
      assert get_resp_header(result, "location") == []
    end

    Repo.update_all(PushedRequest, set: [expires_at: 1])
    assert begin(c).status == 400
  end

  defp consent_page(c) do
    start = begin(c)
    assert redirected_to(start, 303) == "/account/login"
    login = start |> browser() |> get("/account/login")

    signed =
      post_form(login, "/account/login", %{
        "identifier" => c.did,
        "password" => "browser password"
      })

    assert redirected_to(signed, 303) == "/oauth/authorize"
    signed |> browser() |> get("/oauth/authorize")
  end

  defp begin(c),
    do:
      get(
        c.conn,
        "/oauth/authorize?" <> URI.encode_query(%{client_id: @client, request_uri: c.uri})
      )

  defp submit(page, params),
    do: post_form(page, "/oauth/authorize", Map.merge(%{"view" => value(page, "view")}, params))

  defp post_form(page, path, params) do
    page
    |> browser()
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(path, URI.encode_query(Map.put(params, "_csrf_token", value(page, "_csrf_token"))))
  end

  defp value(page, name),
    do: Regex.run(~r/name="#{name}" value="([^"]+)"/, page.resp_body) |> Enum.at(1)

  defp browser(conn),
    do:
      conn
      |> recycle()
      |> Map.put(:remote_ip, conn.remote_ip)
      |> put_private(:plug_skip_csrf_protection, false)

  defp exchange(c, code) do
    c.conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("dpop", proof(c, "/oauth/token"))
    |> post(
      "/oauth/token",
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "client_id" => @client,
        "code" => code,
        "redirect_uri" => @redirect_uri,
        "code_verifier" => c.verifier
      })
    )
  end

  defp proof(c, path, method \\ "POST", extra \\ %{}) do
    {_, public} = JOSE.JWK.to_public_map(c.key)

    claims =
      Map.merge(
        %{
          "jti" => random(),
          "iat" => System.system_time(:second),
          "nonce" => c.nonce,
          "htm" => method,
          "htu" => AtollWeb.Endpoint.url() <> path
        },
        extra
      )

    JOSE.JWT.sign(c.key, %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
