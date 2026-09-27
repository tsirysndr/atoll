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

  test "discovered endpoints complete PAR, browser consent, token exchange and resource access",
       c do
    prior = Application.fetch_env(:atoll, :localhost_dids_enabled)
    Application.put_env(:atoll, :localhost_dids_enabled, true)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:atoll, :localhost_dids_enabled, value)
        :error -> Application.delete_env(:atoll, :localhost_dids_enabled)
      end
    end)

    resource =
      get(c.conn, AtollWeb.Endpoint.url() <> "/.well-known/oauth-protected-resource")
      |> json_response(200)

    metadata =
      get(
        c.conn,
        hd(resource["authorization_servers"]) <> "/.well-known/oauth-authorization-server"
      )
      |> json_response(200)

    Repo.delete_all(PushedRequest)
    verifier = random()

    params =
      c.params
      |> Map.put("response_mode", "query")
      |> Map.put(
        "code_challenge",
        :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
      )

    c = %{c | params: params, verifier: verifier, nonce: "initial-nonce"}
    par_url = metadata["pushed_authorization_request_endpoint"]

    challenge =
      c.conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("dpop", proof(c, URI.parse(par_url).path))
      |> post(par_url, URI.encode_query(params))

    assert json_response(challenge, 400)["error"] == "use_dpop_nonce"
    c = %{c | nonce: hd(get_resp_header(challenge, "dpop-nonce"))}

    pushed =
      c.conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("dpop", proof(c, URI.parse(par_url).path))
      |> post(par_url, URI.encode_query(params))
      |> json_response(201)

    c = c |> Map.put(:metadata, metadata) |> Map.put(:uri, pushed["request_uri"])
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
           |> get(resource["resource"] <> "/xrpc/com.atproto.server.getSession")
           |> json_response(200)

    sessions = approved |> browser() |> get("/account/sessions")
    assert sessions.resp_body =~ "Revoke access"
    logout = post_form(sessions, "/account/logout", %{})
    assert redirected_to(logout, 303) == "/account/login"
    assert Repo.aggregate(Atoll.OAuth.Session, :count) == 0
  end

  test "granular repository consent displays requested operations and excludes unchecked scopes",
       c do
    # A localhost client's declared wildcard covers narrower requested permissions.
    client =
      "http://localhost?" <>
        URI.encode_query(%{"scope" => "atproto repo:*", "redirect_uri" => @redirect_uri})

    verifier = random()
    scopes = for n <- 1..15, do: "repo:com.example.record#{n}?action=create"

    params =
      c.params
      |> Map.put("client_id", client)
      |> Map.put("scope", Enum.join(["atproto" | scopes], " "))
      |> Map.put(
        "code_challenge",
        :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
      )

    Repo.delete_all(PushedRequest)
    {:ok, %{request_uri: uri}} = PAR.push(params, [proof(c, "/oauth/par")])

    start =
      get(c.conn, "/oauth/authorize?" <> URI.encode_query(%{client_id: client, request_uri: uri}))

    login = start |> browser() |> get("/account/login")

    signed =
      post_form(login, "/account/login", %{
        "identifier" => c.did,
        "password" => "browser password"
      })

    page = signed |> browser() |> get("/oauth/authorize")
    assert html_response(page, 200) =~ "create in com.example.record1"
    refute page.resp_body =~ "use application services"
    assert submit(page, %{"decision" => "approve", "permission_999" => "yes"}).status == 400
    assert submit(page, %{"decision" => "approve", "permission_1" => "repo:*"}).status == 400
    # More than thirteen form fields are valid only for bounded consent choices.
    choices = for n <- 1..14, into: %{}, do: {"permission_#{n}", "yes"}
    approved = submit(page, Map.put(choices, "decision", "approve"))

    callback =
      redirected_to(approved, 303) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    tokens =
      c.conn
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> put_req_header("dpop", proof(c, "/oauth/token"))
      |> post(
        "/oauth/token",
        URI.encode_query(%{
          "grant_type" => "authorization_code",
          "client_id" => client,
          "code" => callback["code"],
          "redirect_uri" => @redirect_uri,
          "code_verifier" => verifier
        })
      )
      |> json_response(200)

    assert tokens["scope"] == Enum.join(["atproto" | Enum.take(scopes, 14)], " ")
    refute tokens["scope"] =~ "record15"
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

  test "create prompt registers an account then requires explicit consent and exchanges its code",
       c do
    c = create_request(c)
    page = signup_page(c)
    assert html_response(page, 200) =~ "Create an account"
    assert get_resp_header(page, "cache-control") == ["no-store"]
    assert get_resp_header(page, "content-security-policy") |> hd() =~ "style-src 'self'"
    accept_registration()
    signed = signup(page)
    assert redirected_to(signed, 303) == "/oauth/authorize"
    assert Repo.aggregate(AuthorizationCode, :count) == 0
    assert {:ok, _} = PAR.get(@client, c.uri)
    account = Repo.one!(Atoll.Accounts.Profile)
    refute account.did == c.did
    consent = begin(%{c | conn: browser(signed)})
    assert html_response(consent, 200) =~ account.did
    approved = submit(consent, %{"decision" => "approve"})

    code =
      redirected_to(approved, 303)
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("code")

    tokens = exchange(c, code) |> json_response(200)
    assert tokens["sub"] == account.did
    assert tokens["scope"] == "atproto"
    assert signup(page).status == 400
  end

  test "an existing browser login cannot bypass create or authorize the old account", c do
    existing = consent_page(c)
    c = create_request(%{c | conn: browser(existing)})
    page = signup_page(c)
    assert html_response(page, 200) =~ "Create an account"

    assert post_form(page, "/oauth/authorize", %{
             "view" => value(page, "view"),
             "decision" => "approve"
           }).status == 400

    assert Repo.aggregate(AuthorizationCode, :count) == 0
    accept_registration()
    signed = signup(page)
    consent = signed |> browser() |> get("/oauth/authorize")
    assert html_response(consent, 200) =~ Repo.one!(Atoll.Accounts.Profile).did
    refute consent.resp_body =~ "<strong>" <> c.did <> "</strong>"
  end

  test "signup requires a live create request, correct view and CSRF before side effects", c do
    assert get(c.conn, "/account/signup").status == 400
    ordinary = begin(c) |> browser() |> get("/account/signup")
    assert ordinary.status == 400
    c = create_request(c)
    page = signup_page(c)

    assert page
           |> browser()
           |> put_req_header("content-type", "application/x-www-form-urlencoded")
           |> post("/account/signup", URI.encode_query(signup_params(page)))
           |> response(403)

    assert signup(page, %{"view" => "wrong"}).status == 400
    assert signup(page, %{"redirect_uri" => "https://evil.example.com"}).status == 400
    assert Repo.aggregate(Atoll.Accounts.Profile, :count) == 0
  end

  test "disabled signup and expired requests cannot create accounts", c do
    c = create_request(c)
    page = signup_page(c)
    Application.put_env(:atoll, :signup_enabled, false)
    assert signup(page).status == 403
    Application.put_env(:atoll, :signup_enabled, true)
    Repo.update_all(PushedRequest, set: [expires_at: 1])
    assert signup(page).status == 400
    assert Repo.aggregate(Atoll.Accounts.Profile, :count) == 0
  end

  test "invitation policy and login hints are enforced before directory publication", c do
    c = create_request(c, %{"login_hint" => "different.users.example.com"})
    page = signup_page(c)
    assert signup(page).status == 400
    assert Repo.aggregate(Atoll.Accounts.Profile, :count) == 0
    Application.put_env(:atoll, :invite_code_required, true)
    assert signup(page, %{"handle" => "different.users.example.com"}).status == 400
    assert Repo.aggregate(Atoll.Accounts.Profile, :count) == 0
    {:ok, invite} = Atoll.Accounts.Invites.create()

    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn _ ->
        [["did=" <> Repo.one!(Atoll.Accounts.Profile).did]]
      end,
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      request:
        Req.new(
          plug: fn conn ->
            row = Repo.one!(Atoll.Identity.PLC.Registration)
            {:ok, key} = Atoll.KeyVault.fetch(row.did)
            {:ok, multikey} = Atoll.Multikey.encode(key.curve, key.public)

            Req.Test.json(conn, %{
              "id" => row.did,
              "alsoKnownAs" => row.operation["alsoKnownAs"],
              "verificationMethod" => [
                %{
                  "id" => row.did <> "#atproto",
                  "type" => "Multikey",
                  "controller" => row.did,
                  "publicKeyMultibase" => multikey
                }
              ],
              "service" => [
                %{
                  "id" => row.did <> "#atproto_pds",
                  "type" => "AtprotoPersonalDataServer",
                  "serviceEndpoint" => AtollWeb.Endpoint.url()
                }
              ]
            })
          end
        )
    )

    accept_registration()

    signed =
      signup(page, %{"handle" => "different.users.example.com", "inviteCode" => invite.code})

    assert redirected_to(signed, 303) == "/oauth/authorize"

    assert signed |> browser() |> get("/oauth/authorize") |> html_response(200) =~
             "Connect an application"
  end

  test "directory failure can resume the same reservation without creating another identity", c do
    c = create_request(c)
    page = signup_page(c)
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 404, ""))
    failed = signup(page)
    assert html_response(failed, 503) =~ "Retry with the same handle"
    reservation = Repo.one!(Atoll.Identity.PLC.Registration)
    refute reservation.completed_at
    accept_registration()
    signed = signup(failed)
    assert redirected_to(signed, 303) == "/oauth/authorize"
    assert Repo.one!(Atoll.Accounts.Profile).did == reservation.did
    assert Repo.get!(Atoll.Identity.PLC.Registration, reservation.did).completed_at
  end

  test "expiry during directory publication keeps the new account without issuing consent", c do
    c = create_request(c)
    page = signup_page(c)
    accept_registration(fn -> Repo.update_all(PushedRequest, set: [expires_at: 1]) end)
    signed = signup(page)
    assert html_response(signed, 200) =~ "Account created"
    assert signed.resp_body =~ "request expired"
    assert Repo.aggregate(AuthorizationCode, :count) == 0

    assert signed |> browser() |> get("/account/sessions") |> html_response(200) =~
             "Connected applications"
  end

  test "passkey sign-in preserves the pushed request and resumes explicit consent", c do
    alias Atoll.Accounts.{Passkeys, Sessions}
    alias Atoll.PasskeyFixtures, as: Fixture
    {:ok, pair} = Sessions.create(c.did, "browser password")
    binding = random()

    {:ok, request} =
      Passkeys.begin_registration(pair.access_jwt, "browser password", binding, "OAuth key")

    fixture = Fixture.new(request.public_key)

    {:ok, key} =
      Passkeys.complete_registration(
        pair.access_jwt,
        binding,
        request.reference,
        Fixture.registration(fixture)
      )

    login = begin(c) |> browser() |> get("/account/login")
    ceremony = post_form(login, "/account/passkeys/login/begin", %{})
    [_, raw] = Regex.run(~r/data-public-key="([^"]+)"/, ceremony.resp_body)

    options =
      raw |> String.replace("&quot;", "\"") |> String.replace("&amp;", "&") |> Jason.decode!()

    fixture = %{
      fixture
      | context: Fixture.context(%{challenge: options["challenge"], rpId: options["rpId"]})
    }

    signed =
      post_form(ceremony, "/account/passkeys/login/finish", %{
        "credential" => Jason.encode!(Fixture.assertion(fixture))
      })

    assert redirected_to(signed, 303) == "/oauth/authorize"
    page = signed |> browser() |> get("/oauth/authorize")
    assert html_response(page, 200) =~ "Connect an application"
    assert Repo.aggregate(AuthorizationCode, :count) == 0
    approved = submit(page, %{"decision" => "approve"})

    code =
      redirected_to(approved, 303)
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("code")

    assert exchange(c, code) |> json_response(200) |> Map.fetch!("sub") == c.did
    assert {:ok, :revoked} = Passkeys.revoke(pair.access_jwt, "browser password", key.id)
    assert Repo.aggregate(Atoll.OAuth.Session, :count) == 0
  end

  defp create_request(c, extra \\ %{}) do
    keys = [
      :pds,
      :signup_enabled,
      :signup_retry,
      :invite_code_required,
      :plc_submission_options,
      :identity_resolution_options
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:atoll, &1)})
    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "https", host: "pds.example.com", port: 443)}
      ],
      []
    )

    on_exit(fn ->
      AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], [])

      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    Application.put_env(:atoll, :pds,
      did: "did:web:pds.example.com",
      available_user_domains: [".users.example.com"]
    )

    Application.put_env(:atoll, :signup_enabled, true)
    Application.put_env(:atoll, :signup_retry, enabled: false, delay_seconds: 300)
    Application.put_env(:atoll, :invite_code_required, false)
    Application.put_env(:atoll, :plc_submission_options, plug: {Req.Test, __MODULE__})
    {:ok, nonce} = Nonce.issue(:authorization)

    params =
      c.params |> Map.delete("login_hint") |> Map.put("prompt", "create") |> Map.merge(extra)

    # Use a new proof and PKCE challenge for a new pushed request.
    verifier = random()

    params =
      Map.put(
        params,
        "code_challenge",
        :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
      )

    c = %{c | nonce: nonce, verifier: verifier, params: params}
    Repo.delete_all(PushedRequest)
    {:ok, %{request_uri: uri}} = PAR.push(params, [proof(c, "/oauth/par")])
    %{c | uri: uri}
  end

  defp signup_page(c) do
    start = begin(c)
    assert redirected_to(start, 303) == "/account/signup"
    start |> browser() |> get("/account/signup")
  end

  defp signup_params(page),
    do: %{
      "view" => value(page, "view"),
      "handle" => "alice.users.example.com",
      "email" => "alice@example.com",
      "password" => "signup account password",
      "inviteCode" => ""
    }

  defp signup(page, changes \\ %{}),
    do: post_form(page, "/account/signup", Map.merge(signup_params(page), changes))

  defp accept_registration(callback \\ fn -> :ok end) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      operation = Jason.decode!(body)
      callback.()
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, operation))
      Plug.Conn.send_resp(conn, 200, "")
    end)
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
        authorization_endpoint(c) <>
          "?" <> URI.encode_query(%{client_id: @client, request_uri: c.uri})
      )

  defp authorization_endpoint(%{metadata: metadata}), do: metadata["authorization_endpoint"]
  defp authorization_endpoint(_), do: "/oauth/authorize"

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
      Map.get(c, :metadata, %{})["token_endpoint"] || "/oauth/token",
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
