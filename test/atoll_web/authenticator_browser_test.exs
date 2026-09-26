defmodule AtollWeb.AuthenticatorBrowserTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.Accounts.{Credentials, Sessions, TOTP, TOTPFactor}
  alias Atoll.Repo

  setup %{conn: conn} do
    for name <- [:session_signing_key, :key_encryption_key] do
      previous = Application.fetch_env(:atoll, name)
      Application.put_env(:atoll, name, :crypto.strong_rand_bytes(32))

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end)
    end

    did = "did:plc:securitybrowser"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    {:ok, _} = Credentials.create(did, "account password")
    id = rem(System.unique_integer([:positive]), 65_536)

    conn = %{
      put_private(conn, :plug_skip_csrf_protection, false)
      | remote_ip: {10, 97, div(id, 256), rem(id, 256)}
    }

    %{conn: conn, did: did}
  end

  test "browser setup, recovery sign-in, code replacement and disabling form a complete flow",
       c do
    page = signed_in(c)
    assert html_response(page, 200) =~ "not enabled"
    setup = form(page, "/account/security/begin", %{password: "account password"})
    assert html_response(setup, 200) =~ "Google Authenticator"
    [_, secret] = Regex.run(~r/<code>([A-Z2-7]{32})<\/code>/, setup.resp_body)
    assert get_resp_header(setup, "cache-control") == ["no-store"]

    assert {:ok, code} =
             TOTP.code(Base.decode32!(secret, padding: false), System.system_time(:second))

    confirmed = form(setup, "/account/security/confirm", %{totpCode: code})
    codes = codes(confirmed)
    assert length(codes) == 10
    assert html_response(confirmed, 200) =~ "shown only now"
    refute confirmed.resp_body =~ secret
    assert Repo.get!(TOTPFactor, c.did).confirmed_at

    security = confirmed |> recycle_browser() |> get("/account/security")
    assert security.resp_body =~ "Recovery codes remaining: <strong>10</strong>"
    for code <- codes, do: refute(security.resp_body =~ code)
    signed_out = form(security, "/account/logout", %{})
    login = signed_out |> recycle_browser() |> get("/account/login")

    signed =
      form(login, "/account/login", %{
        identifier: c.did,
        password: "account password",
        totpCode: hd(codes)
      })

    assert redirected_to(signed, 303) == "/account/sessions"
    security = signed |> recycle_browser() |> get("/account/security")
    assert security.resp_body =~ "Recovery codes remaining: <strong>9</strong>"

    replaced =
      form(security, "/account/security/recovery", %{
        password: "account password",
        totpCode: Enum.at(codes, 1)
      })

    fresh = codes(replaced)
    assert length(fresh) == 10
    refute Enum.any?(fresh, &(&1 in codes))
    security = replaced |> recycle_browser() |> get("/account/security")

    disabled =
      form(security, "/account/security/disable", %{
        password: "account password",
        totpCode: hd(fresh)
      })

    assert html_response(disabled, 200) =~ "has been disabled"
    refute Repo.get(TOTPFactor, c.did)
    assert {:ok, _} = Sessions.create(c.did, "account password")
  end

  test "management requires a live session and every mutation requires CSRF", c do
    assert get(c.conn, "/account/security") |> redirected_to(303) == "/account/login"
    page = signed_in(c)

    for path <- ~w(begin confirm recovery disable) do
      conn =
        recycle_browser(page)
        |> put_req_header("content-type", "application/x-www-form-urlencoded")

      assert post(
               conn,
               "/account/security/" <> path,
               URI.encode_query(%{password: "account password", totpCode: "123456"})
             ).status == 403

      assert get(recycle_browser(page), "/account/security/" <> path).status == 405
    end

    refute Repo.get(TOTPFactor, c.did)
    Repo.delete_all(Atoll.Accounts.Session)

    assert form(page, "/account/security/begin", %{password: "account password"})
           |> redirected_to(303) == "/account/login"
  end

  test "setup failures preserve a retry form and do not echo submitted secrets", c do
    page = signed_in(c)
    denied = form(page, "/account/security/begin", %{password: "incorrect password"})
    assert html_response(denied, 401) =~ "not accepted"
    refute denied.resp_body =~ "incorrect password"
    setup = form(denied, "/account/security/begin", %{password: "account password"})
    bad = form(setup, "/account/security/confirm", %{totpCode: "invalid code"})
    assert html_response(bad, 400) =~ "Finish setup"
    refute bad.resp_body =~ "invalid code"
    assert Repo.get!(TOTPFactor, c.did).attempts == 1

    assert form(bad, "/account/security/begin", %{
             password: "account password",
             did: "did:plc:someoneelse"
           }).status == 400
  end

  test "XRPC recovery codes retain one-time use and do not replace the password", c do
    page = signed_in(c)
    setup = form(page, "/account/security/begin", %{password: "account password"})
    [_, secret] = Regex.run(~r/<code>([A-Z2-7]{32})<\/code>/, setup.resp_body)
    {:ok, code} = TOTP.code(Base.decode32!(secret, padding: false), System.system_time(:second))
    recovery = form(setup, "/account/security/confirm", %{totpCode: code}) |> codes() |> hd()
    conn = put_req_header(c.conn, "content-type", "application/json")
    body = %{identifier: c.did, password: "account password", totpCode: recovery}

    assert post(
             conn,
             "/xrpc/com.atproto.server.createSession",
             Jason.encode!(%{body | password: "wrong password"})
           ).status == 401

    assert post(conn, "/xrpc/com.atproto.server.createSession", Jason.encode!(body)).status == 200

    assert %{"error" => "InvalidAuthFactorToken"} =
             post(conn, "/xrpc/com.atproto.server.createSession", Jason.encode!(body))
             |> json_response(401)
  end

  test "browser pages load local Tailwind styles without inline style permission", c do
    page = get(c.conn, "/account/login")
    assert page.resp_body =~ "href=\"/assets/account.css\""
    refute page.resp_body =~ "<style>"
    [csp] = get_resp_header(page, "content-security-policy")
    assert csp =~ "style-src 'self'"
    refute csp =~ "unsafe-inline"
  end

  defp signed_in(c) do
    get(c.conn, "/account/login")
    |> form("/account/login", %{identifier: c.did, password: "account password"})
    |> recycle_browser()
    |> get("/account/security")
  end

  defp codes(conn),
    do: Regex.scan(~r/<li>([A-Z2-7]{26})<\/li>/, conn.resp_body) |> Enum.map(&List.last/1)

  defp form(page, path, params) do
    [_, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body)

    page
    |> recycle_browser()
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(path, URI.encode_query(Map.put(params, :_csrf_token, csrf)))
  end

  defp recycle_browser(conn),
    do:
      conn
      |> recycle()
      |> Map.put(:remote_ip, conn.remote_ip)
      |> put_private(:plug_skip_csrf_protection, false)
end
