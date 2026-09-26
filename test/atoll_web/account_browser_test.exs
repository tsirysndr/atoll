defmodule AtollWeb.AccountBrowserTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{Credentials, Sessions}
  alias Atoll.OAuth.Session

  setup %{conn: conn} do
    previous = Application.fetch_env(:atoll, :session_signing_key)
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atoll, :session_signing_key, value)
        :error -> Application.delete_env(:atoll, :session_signing_key)
      end
    end)

    did = "did:plc:browseraccount"
    {:ok, _} = Repositories.create(did, SigningKey.generate())
    {:ok, _} = Credentials.create(did, "account password")
    {:ok, pair} = Sessions.create_for_account(did)
    {:ok, claims} = Atoll.Accounts.Tokens.verify(pair.access_jwt, :access)

    session =
      Repo.insert!(%Session{
        id: random(),
        did: did,
        source_session_id: claims["sid"],
        issuer: AtollWeb.Endpoint.url(),
        client_id: "https://app.example.com/<script>alert(1)</script>",
        scope: "atproto transition:generic",
        dpop_jkt: random(),
        expires_at: System.system_time(:second) + 3600
      })

    id = rem(System.unique_integer([:positive]), 65_536)

    %{
      conn: %{
        put_private(conn, :plug_skip_csrf_protection, false)
        | remote_ip: {10, 96, div(id, 256), rem(id, 256)}
      },
      did: did,
      session: session,
      pair: pair
    }
  end

  test "login, escaped inventory, revocation and logout form a complete browser flow", c do
    login = get(c.conn, "/account/login")
    assert html_response(login, 200) =~ "Email or DID"
    assert get_resp_header(login, "cache-control") == ["no-store"]
    assert get_resp_header(login, "content-security-policy") |> hd() =~ "frame-ancestors 'none'"
    cookie = login.resp_cookies["_atoll_account"]
    assert cookie.http_only
    assert cookie.same_site == "Lax"
    assert cookie.max_age == 3600
    signed_in = form(login, "/account/login", %{identifier: c.did, password: "account password"})
    assert redirected_to(signed_in, 303) == "/account/sessions"
    refute signed_in.resp_body =~ "account password"
    page = signed_in |> browser_recycle() |> get("/account/sessions")
    body = html_response(page, 200)
    assert body =~ "Connected applications"
    assert body =~ "&lt;script&gt;"
    refute body =~ "<script>"
    assert body =~ c.session.id
    assert get_resp_header(page, "referrer-policy") == ["no-referrer"]
    revoked = form(page, "/account/sessions/revoke", %{id: c.session.id})
    assert redirected_to(revoked, 303) == "/account/sessions"
    refute Repo.get(Session, c.session.id)
    page = revoked |> browser_recycle() |> get("/account/sessions")
    assert html_response(page, 200) =~ "No active OAuth sessions"
    before = Repo.aggregate(Atoll.Accounts.Session, :count)
    logout = form(page, "/account/logout", %{})
    assert redirected_to(logout, 303) == "/account/login"
    assert Repo.aggregate(Atoll.Accounts.Session, :count) == before - 1

    assert logout |> browser_recycle() |> get("/account/sessions") |> redirected_to(303) ==
             "/account/login"

    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
  end

  test "CSRF is required for login, revocation and logout", c do
    login = get(c.conn, "/account/login")

    conn =
      browser_recycle(login)
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    assert post(
             conn,
             "/account/login",
             URI.encode_query(%{identifier: c.did, password: "account password"})
           ).status == 403

    signed = form(login, "/account/login", %{identifier: c.did, password: "account password"})

    for path <- ["/account/sessions/revoke", "/account/logout"] do
      conn =
        browser_recycle(signed)
        |> put_req_header("content-type", "application/x-www-form-urlencoded")

      assert post(conn, path, URI.encode_query(%{id: c.session.id, _csrf_token: "bad"})).status ==
               403
    end

    assert Repo.get(Session, c.session.id)
  end

  test "invalid login, forged cookies and stale source sessions cannot manage grants", c do
    login = get(c.conn, "/account/login")
    failed = form(login, "/account/login", %{identifier: c.did, password: "wrong password"})
    assert html_response(failed, 401) =~ "Sign-in failed"
    refute failed.resp_body =~ "wrong password"

    assert failed |> browser_recycle() |> get("/account/sessions") |> redirected_to(303) ==
             "/account/login"

    signed = form(login, "/account/login", %{identifier: c.did, password: "account password"})

    forged =
      browser_recycle(signed)
      |> put_req_cookie("_atoll_account", signed.resp_cookies["_atoll_account"].value <> "x")

    assert get(forged, "/account/sessions") |> redirected_to(303) == "/account/login"
    Repo.delete_all(Atoll.Accounts.Session)

    assert signed |> browser_recycle() |> get("/account/sessions") |> redirected_to(303) ==
             "/account/login"
  end

  test "email login works and app passwords cannot open the account UI", c do
    Repo.insert!(%Atoll.Accounts.Profile{
      did: c.did,
      handle: "browser.example.com",
      email: "owner@example.com"
    })

    login = get(c.conn, "/account/login")

    signed =
      form(login, "/account/login", %{
        identifier: "owner@example.com",
        password: "account password"
      })

    assert redirected_to(signed, 303) == "/account/sessions"

    {:ok, app} =
      Atoll.Accounts.AppPasswords.create(c.pair.access_jwt, %{"name" => "browser attempt"})

    before = Repo.aggregate(Atoll.Accounts.Session, :count)
    failed = form(login, "/account/login", %{identifier: c.did, password: app.password})
    assert failed.status == 401
    assert Repo.aggregate(Atoll.Accounts.Session, :count) == before
  end

  test "email-factor accounts must complete their challenge", c do
    Repo.insert!(%Atoll.Accounts.Profile{
      did: c.did,
      handle: "factor.example.com",
      email: "factor@example.com",
      email_auth_factor: true,
      email_confirmed_at: DateTime.utc_now(),
      auth_factor_requested_at: System.system_time(:second)
    })

    login = get(c.conn, "/account/login")
    before = Repo.aggregate(Atoll.Accounts.Session, :count)
    result = form(login, "/account/login", %{identifier: c.did, password: "account password"})
    assert html_response(result, 401) =~ "Check your email"
    assert Repo.aggregate(Atoll.Accounts.Session, :count) == before
  end

  test "browser expiry is enforced by the server even with an otherwise valid account JWT", c do
    conn =
      c.conn
      |> init_test_session(%{
        account_access: c.pair.access_jwt,
        account_refresh: c.pair.refresh_jwt,
        account_expires_at: 1
      })

    assert get(conn, "/account/sessions") |> redirected_to(303) == "/account/login"
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
  end

  test "request methods, duplicate fields and oversized forms are rejected", c do
    assert get(c.conn, "/account/logout").status == 405
    assert get(c.conn, "/account/%6cogin").status == 400
    login = get(c.conn, "/account/login")

    conn =
      browser_recycle(login)
      |> put_req_header("content-type", "application/x-www-form-urlencoded")

    assert post(conn, "/account/login", "identifier=a&identifier=b").status == 400
    assert post(conn, "/account/login", "x=" <> String.duplicate("x", 9000)).status == 413
  end

  test "login rate limits apply before parsing", c do
    for _ <- 1..10,
        do: Atoll.Accounts.SessionLimiter.check({:account_login, c.conn.remote_ip}, 10)

    result =
      c.conn |> put_req_header("content-type", "text/plain") |> post("/account/login", "bad")

    assert result.status == 429
    assert get_resp_header(result, "retry-after") != []
  end

  test "enabled authenticators are required by browser login", c do
    next = enable_totp(c)
    login = get(c.conn, "/account/login")
    result = form(login, "/account/login", %{identifier: c.did, password: "account password"})
    assert html_response(result, 401) =~ "six-digit code"

    signed =
      form(result, "/account/login", %{
        identifier: c.did,
        password: "account password",
        totpCode: next
      })

    assert redirected_to(signed, 303) == "/account/sessions"
  end

  test "XRPC password login accepts totpCode and rejects its replay", c do
    next = enable_totp(c)
    body = %{identifier: c.did, password: "account password"}
    conn = put_req_header(c.conn, "content-type", "application/json")

    assert %{"error" => "AuthFactorTokenRequired"} =
             post(conn, "/xrpc/com.atproto.server.createSession", Jason.encode!(body))
             |> json_response(401)

    body = Map.put(body, :totpCode, next)

    assert %{"accessJwt" => _} =
             post(conn, "/xrpc/com.atproto.server.createSession", Jason.encode!(body))
             |> json_response(200)

    assert %{"error" => "InvalidAuthFactorToken"} =
             post(conn, "/xrpc/com.atproto.server.createSession", Jason.encode!(body))
             |> json_response(401)
  end

  defp enable_totp(c) do
    previous = Application.fetch_env(:atoll, :key_encryption_key)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atoll, :key_encryption_key, value)
        :error -> Application.delete_env(:atoll, :key_encryption_key)
      end
    end)

    {:ok, enrollment} = Atoll.Accounts.Authenticator.begin(c.pair.access_jwt, "account password")
    secret = Base.decode32!(enrollment.secret, padding: false)
    now = System.system_time(:second)
    {:ok, code} = Atoll.Accounts.TOTP.code(secret, now)

    assert {:ok, %{recovery_codes: _}} =
             Atoll.Accounts.Authenticator.confirm(c.pair.access_jwt, code)

    {:ok, next} = Atoll.Accounts.TOTP.code(secret, now + 30)
    next
  end

  defp form(page, path, params) do
    [_, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body)

    page
    |> browser_recycle()
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(path, URI.encode_query(Map.put(params, :_csrf_token, csrf)))
  end

  defp browser_recycle(conn) do
    conn
    |> recycle()
    |> Map.put(:remote_ip, conn.remote_ip)
    |> put_private(:plug_skip_csrf_protection, false)
  end

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
