defmodule AtollWeb.PasskeyBrowserTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.Accounts.{Credentials, Passkey, PasskeyChallenge}
  alias Atoll.PasskeyFixtures, as: Fixture
  alias Atoll.Repo
  @password "browser passkey password"
  @begin "/account/passkeys/register/begin"
  @finish "/account/passkeys/register/finish"
  @login_begin "/account/passkeys/login/begin"
  @login_finish "/account/passkeys/login/finish"

  setup %{conn: conn} do
    for {key, value} <- [
          session_signing_key: :crypto.strong_rand_bytes(32),
          key_encryption_key: :crypto.strong_rand_bytes(32),
          passkeys_enabled: true
        ] do
      previous = Application.fetch_env(:atoll, key)
      Application.put_env(:atoll, key, value)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end)
    end

    did = "did:plc:browserpasskey"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    {:ok, _} = Credentials.create(did, @password)
    id = rem(System.unique_integer([:positive]), 65_536)

    %{
      conn: %{
        put_private(conn, :plug_skip_csrf_protection, false)
        | remote_ip: {10, 102, div(id, 256), rem(id, 256)}
      },
      did: did
    }
  end

  test "complete registration, discoverable login, removal and password recovery", c do
    page = manage(c)
    assert html_response(page, 200) =~ "You have no passkeys yet"
    {created, fixture} = enroll(page)
    page = created |> browser() |> get("/account/passkeys")
    assert html_response(page, 200) =~ "Laptop"
    assert page.resp_body =~ "Lost a passkey?"
    refute page.resp_body =~ "public_key"
    sessions = page |> browser() |> get("/account/sessions")
    logout = form(sessions, "/account/logout", %{})
    login = logout |> browser() |> get("/account/login")
    assert login.resp_body =~ "Sign in with a passkey"
    ceremony = form(login, @login_begin, %{})
    assert html_response(ceremony, 200) =~ "Continue with passkey"
    assert get_resp_header(ceremony, "content-security-policy") |> hd() =~ "script-src 'self'"
    assert ceremony.resp_body =~ "/assets/passkeys.js"
    assert get_resp_header(ceremony, "cache-control") == ["no-store"]

    assert get_resp_header(ceremony, "permissions-policy") |> hd() =~
             "publickey-credentials-get=(self)"

    options = options(ceremony)
    refute Map.has_key?(options, "allowCredentials")

    fixture = %{
      fixture
      | context: Fixture.context(%{challenge: options["challenge"], rpId: options["rpId"]})
    }

    signed =
      form(ceremony, @login_finish, %{credential: Jason.encode!(Fixture.assertion(fixture))})

    assert redirected_to(signed, 303) == "/account/sessions"

    refute signed.resp_cookies["_atoll_account"].value ==
             ceremony.resp_cookies["_atoll_account"].value

    assert form(ceremony, @login_finish, %{credential: Jason.encode!(Fixture.assertion(fixture))}).status ==
             400

    page = signed |> browser() |> get("/account/passkeys")

    revoked =
      form(page, "/account/passkeys/revoke", %{id: Repo.one!(Passkey).id, password: @password})

    assert redirected_to(revoked, 303) == "/account/login"
    assert Repo.aggregate(Passkey, :count) == 0
    assert html_response(manage(%{c | conn: browser(revoked)}), 200) =~ "You have no passkeys yet"
  end

  test "ceremonies require CSRF, exact fields and the encrypted browser context", c do
    page = manage(c)

    assert page
           |> browser()
           |> put_req_header("content-type", "application/x-www-form-urlencoded")
           |> post(@begin, "name=Key&password=whatever")
           |> response(403)

    assert form(page, @begin, %{
             name: "Key",
             password: @password,
             origin: "https://evil.example.com"
           }).status == 400

    ceremony = form(page, @begin, %{name: "Key", password: @password})
    fixture = registration_fixture(ceremony)
    credential = Jason.encode!(Fixture.registration(fixture))
    # A different password-authenticated browser lacks this ceremony's binding.
    other = manage(%{c | conn: build_conn() |> Map.put(:remote_ip, c.conn.remote_ip)})
    assert form(other, @finish, %{credential: credential}).status == 400
    assert Repo.aggregate(Passkey, :count) == 0

    assert redirected_to(form(ceremony, @finish, %{credential: credential}), 303) ==
             "/account/passkeys"

    assert form(ceremony, @finish, %{credential: credential}).status == 400
  end

  test "JSON duplicates and unknown fields fail before enrollment", c do
    page = manage(c)
    ceremony = form(page, @begin, %{name: "Key", password: @password})
    raw = Fixture.registration(registration_fixture(ceremony)) |> Jason.encode!()

    for invalid <- [
          String.replace_suffix(raw, "}", ",\"type\":\"public-key\"}"),
          String.replace_suffix(raw, "}", ",\"extra\":true}"),
          "[]",
          "null"
        ] do
      assert form(ceremony, @finish, %{credential: invalid}).status == 400
    end

    assert Repo.aggregate(Passkey, :count) == 0
  end

  test "expiration and disabled ceremonies fail locally while password management remains", c do
    page = manage(c)
    ceremony = form(page, @begin, %{name: "Key", password: @password})
    Repo.update_all(PasskeyChallenge, set: [expires_at: 1])

    assert form(ceremony, @finish, %{
             credential: Jason.encode!(Fixture.registration(registration_fixture(ceremony)))
           }).status == 400

    Application.put_env(:atoll, :passkeys_enabled, false)
    assert form(page, @begin, %{name: "Key", password: @password}).status == 403
    login = get(c.conn, "/account/login")
    refute login.resp_body =~ "Sign in with a passkey"
    assert form(login, @login_begin, %{}).status == 403
    assert page |> browser() |> get("/account/passkeys") |> html_response(200) =~ "disabled"
  end

  test "names are escaped and script permission is limited to ceremony pages", c do
    page = manage(c)
    {created, _} = enroll(page, "<script>alert(1)</script>")
    inventory = created |> browser() |> get("/account/passkeys")
    assert inventory.resp_body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute inventory.resp_body =~ "<script>"
    refute get_resp_header(inventory, "content-security-policy") |> hd() =~ "script-src"
    refute get_resp_header(inventory, "content-security-policy") |> hd() =~ "unsafe-inline"
  end

  test "canonical paths, form size bounds and shared sign-in rate limits", c do
    for path <- [@begin, @finish, @login_begin, @login_finish, "/account/passkeys/revoke"] do
      assert get(c.conn, path).status == 405
    end

    assert get(c.conn, "/account/%70asskeys").status == 400
    page = get(c.conn, "/account/login")
    too_large = "credential=" <> String.duplicate("x", 49_153)

    assert page
           |> browser()
           |> put_req_header("content-type", "application/x-www-form-urlencoded")
           |> post(@login_finish, too_large)
           |> response(413)

    for _ <- 1..9, do: assert(form(page, @login_begin, %{}).status == 200)
    assert form(page, @login_begin, %{}).status == 429
    assert Repo.aggregate(PasskeyChallenge, :count) == 9
  end

  defp manage(c) do
    login = get(c.conn, "/account/login")
    signed = form(login, "/account/login", %{identifier: c.did, password: @password})
    assert redirected_to(signed, 303) == "/account/sessions"
    signed |> browser() |> get("/account/passkeys")
  end

  defp enroll(page, name \\ "Laptop") do
    ceremony = form(page, @begin, %{name: name, password: @password})
    assert html_response(ceremony, 200) =~ "Save your passkey"
    fixture = registration_fixture(ceremony)
    created = form(ceremony, @finish, %{credential: Jason.encode!(Fixture.registration(fixture))})
    assert redirected_to(created, 303) == "/account/passkeys"
    {created, fixture}
  end

  defp registration_fixture(page) do
    options = options(page)

    Fixture.new(%{
      challenge: options["challenge"],
      rp: %{id: options["rp"]["id"]},
      user: %{id: options["user"]["id"]}
    })
  end

  defp options(page) do
    [_, raw] = Regex.run(~r/data-public-key="([^"]+)"/, page.resp_body)
    raw |> String.replace("&quot;", "\"") |> String.replace("&amp;", "&") |> Jason.decode!()
  end

  defp csrf(page),
    do: Regex.run(~r/name="_csrf_token" value="([^"]+)"/, page.resp_body) |> Enum.at(1)

  defp form(page, path, fields),
    do:
      page
      |> browser()
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> post(path, URI.encode_query(Map.put(fields, :_csrf_token, csrf(page))))

  defp browser(conn),
    do:
      conn
      |> recycle()
      |> Map.put(:remote_ip, conn.remote_ip)
      |> put_private(:plug_skip_csrf_protection, false)
end
