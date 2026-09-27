defmodule AtollWeb.XRPCProxyTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, KeyVault, Repositories, SigningKey, OAuthFixture}
  alias Atoll.Accounts.{Credentials, Sessions}
  @did "did:plc:proxycaller"
  @service "did:web:appview.example.com"
  @aud @service <> "#bsky_appview"
  @nsid "app.bsky.feed.getTimeline"
  @path "/xrpc/" <> @nsid
  @scope "atproto rpc:*?aud=did:web:appview.example.com%23bsky_appview"

  setup %{conn: conn} do
    keys = [
      :session_signing_key,
      :key_encryption_key,
      :proxy_options,
      :appview_proxy,
      :mod_service_proxy,
      :report_service_proxy,
      :record_write_rate_limit,
      :xrpc_rate_limit
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:atoll, &1)})

    for key <- [:session_signing_key, :key_encryption_key],
        do: Application.put_env(:atoll, key, :crypto.strong_rand_bytes(32))

    for key <- [:appview_proxy, :mod_service_proxy, :report_service_proxy],
        do: Application.delete_env(:atoll, key)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, :stored} = KeyVault.store(@did, key)
    {:ok, _} = Credentials.create(@did, "proxy account password")
    {:ok, pair} = Sessions.create(@did, "proxy account password")
    id = rem(System.unique_integer([:positive]), 65_536)
    conn = %{conn | remote_ip: {10, 97, div(id, 256), rem(id, 256)}}
    configure(fn conn -> Req.Test.json(conn, %{proxied: true}) end)
    %{conn: conn, pair: pair, key: key}
  end

  defp configure(upstream, before_resolve \\ fn -> :ok end) do
    Application.put_env(:atoll, :proxy_options,
      resolver: [
        lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
        request:
          Req.new(
            plug: fn conn ->
              refute Repo.in_transaction?()
              before_resolve.()

              Req.Test.json(conn, %{
                "id" => @service,
                "service" => [
                  %{
                    "id" => "#bsky_appview",
                    "type" => "BskyAppView",
                    "serviceEndpoint" => "https://api.example.com"
                  }
                ]
              })
            end
          )
      ],
      lookup: fn "api.example.com" -> {:ok, {1, 1, 1, 1}} end,
      request:
        Req.new(
          plug: fn conn ->
            refute Repo.in_transaction?()
            upstream.(conn)
          end
        )
    )
  end

  defp legacy(c),
    do:
      c.conn
      |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("atproto-proxy", @aud)

  defp oauth(client, path \\ @path, method \\ "GET"),
    do: OAuthFixture.conn(client, path, method) |> put_req_header("atproto-proxy", @aud)

  defp claims(conn, key, nsid, aud \\ nil) do
    ["Bearer " <> jwt] = get_req_header(conn, "authorization")
    [header, payload, signature] = String.split(jwt, ".")
    <<r::256, s::256>> = Base.url_decode64!(signature, padding: false)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

    assert :crypto.verify(:ecdsa, :sha256, header <> "." <> payload, der, [key.public, :secp256k1])

    claims = payload |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert claims["iss"] == @did
    # Phase 1 of service-auth updates keeps a bare-DID audience in the JWT.
    assert claims["aud"] == (aud || @service)
    assert claims["lxm"] == nsid
    assert claims["exp"] - claims["iat"] == 60
    assert byte_size(claims["jti"]) == 32
    claims
  end

  test "legacy explicit requests sign a service-bound token and preserve queries and response headers",
       c do
    configure(fn conn ->
      claims(conn, c.key, @nsid)
      assert conn.host == "1.1.1.1"
      assert get_req_header(conn, "host") == ["api.example.com"]
      assert conn.query_string == "cursor=a%2Bb&uris=one&uris=two"

      for name <- ~w(cookie dpop atproto-proxy x-forwarded-for),
          do: assert(get_req_header(conn, name) == [])

      conn
      |> put_resp_header("set-cookie", "evil=1")
      |> put_resp_header("atproto-repo-rev", "rev")
      |> put_resp_header("access-control-allow-origin", "https://evil.example.com")
      |> Req.Test.json(%{proxied: true})
    end)

    response =
      legacy(c)
      |> put_req_header("cookie", "local=secret")
      |> get(@path <> "?cursor=a%2Bb&uris=one&uris=two")

    assert json_response(response, 200) == %{"proxied" => true}
    assert get_resp_header(response, "set-cookie") == []
    assert get_resp_header(response, "access-control-allow-origin") == ["*"]
    assert get_resp_header(response, "atproto-repo-rev") == ["rev"]
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(response, "content-security-policy") == ["sandbox; default-src 'none'"]
  end

  test "OAuth GET and POST use RPC scope and never forward the proof or access token", c do
    client = OAuthFixture.grant(c.pair, @scope)

    configure(fn conn ->
      claims(conn, c.key, @nsid)
      assert get_req_header(conn, "dpop") == []
      refute get_req_header(conn, "authorization") == ["Bearer " <> client.token]

      if conn.method == "POST" do
        assert {:ok, <<0, 255, 1>>, conn} = read_body(conn)
        assert get_req_header(conn, "content-type") == ["application/octet-stream"]
        send_resp(conn, 202, "accepted")
      else
        Req.Test.json(conn, %{proxied: true})
      end
    end)

    assert oauth(client) |> get(@path) |> json_response(200) == %{"proxied" => true}

    result =
      oauth(client, @path, "POST")
      |> put_req_header("content-type", "application/octet-stream")
      |> post(@path, <<0, 255, 1>>)

    assert result.status == 202
    assert result.resp_body == "accepted"
    assert [_nonce] = get_resp_header(result, "dpop-nonce")
  end

  test "wrong audience or method grants and replayed or mismatched proofs fail before resolution",
       c do
    client =
      OAuthFixture.grant(
        c.pair,
        "atproto rpc:#{@nsid}?aud=did:web:appview.example.com%23bsky_appview"
      )

    configure(fn _ -> flunk("upstream must not run") end, fn -> flunk("must not resolve") end)
    conn = oauth(client) |> put_req_header("atproto-proxy", @service <> "#other")
    assert conn |> get(@path) |> json_response(403) == %{"error" => "insufficient_scope"}
    other = "/xrpc/app.bsky.feed.getFeed"
    assert oauth(client, other) |> get(other) |> json_response(403)
    assert oauth(client) |> post(@path, "invalid JSON") |> json_response(401)
    assert oauth(client, other) |> get(@path) |> json_response(401)

    proof = OAuthFixture.proof(client, @path, "GET")
    configure(fn _ -> flunk("unresolved target") end)

    Application.put_env(:atoll, :proxy_options,
      resolver: [lookup: fn _ -> {:error, :dns_failed} end]
    )

    request = oauth(client) |> put_req_header("dpop", proof)
    assert request |> get(@path) |> json_response(502)
    assert request |> get(@path) |> json_response(401) == %{"error" => "invalid_dpop_proof"}
  end

  test "base and repository permissions do not grant proxy access", c do
    client = OAuthFixture.grant(c.pair, "atproto repo:app.bsky.feed.post?action=create")
    configure(fn _ -> flunk("must not send") end, fn -> flunk("must not resolve") end)
    assert oauth(client) |> get(@path) |> json_response(403)
    local = "/xrpc/com.atproto.repo.createRecord"
    assert oauth(client, local, "POST") |> post(local, "broken") |> json_response(403)
  end

  test "OAuth grants are rechecked after resolution", c do
    client = OAuthFixture.grant(c.pair, @scope)

    configure(fn _ -> flunk("revoked grant must not send") end, fn ->
      Repo.delete_all(Atoll.OAuth.Session)
    end)

    assert oauth(client) |> get(@path) |> json_response(401) == %{"error" => "invalid_token"}
  end

  test "OAuth scope narrowing during resolution prevents signing", c do
    client = OAuthFixture.grant(c.pair, @scope)

    configure(fn _ -> flunk("narrowed grant must not send") end, fn ->
      Repo.update_all(Atoll.OAuth.AccessToken, set: [scope: "atproto"])
    end)

    assert oauth(client) |> get(@path) |> json_response(403) == %{"error" => "insufficient_scope"}
  end

  test "permission-set RPC grants use the token snapshot after cache eviction", c do
    document = %{
      "$type" => "com.atproto.lexicon.schema",
      "lexicon" => 1,
      "id" => "app.bsky.auth",
      "defs" => %{
        "main" => %{
          "type" => "permission-set",
          "title" => "Timeline",
          "permissions" => [
            %{"type" => "permission", "resource" => "rpc", "lxm" => [@nsid], "inheritAud" => true}
          ]
        }
      }
    }

    Repo.insert!(%Atoll.OAuth.PermissionSetCache{
      nsid: "app.bsky.auth",
      document: document,
      provenance: %{},
      fetched_at: System.system_time(:second),
      retry_at: System.system_time(:second)
    })

    client =
      OAuthFixture.grant(
        c.pair,
        "atproto include:app.bsky.auth?aud=did:web:appview.example.com%23bsky_appview"
      )

    Repo.delete_all(Atoll.OAuth.PermissionSetCache)
    assert oauth(client) |> get(@path) |> json_response(200) == %{"proxied" => true}
    other = "/xrpc/app.bsky.feed.getFeed"
    assert oauth(client, other) |> get(other) |> json_response(403)

    assert oauth(client)
           |> put_req_header("atproto-proxy", @service <> "#other")
           |> get(@path)
           |> json_response(403)
  end

  test "deactivation during OAuth resolution prevents signing", c do
    client = OAuthFixture.grant(c.pair, @scope)

    configure(fn _ -> flunk("inactive account must not send") end, fn ->
      {:ok, _} = Repositories.set_status(@did, :deactivated)
    end)

    assert oauth(client) |> get(@path) |> json_response(401)
  end

  test "standard app passwords cannot proxy chat while privileged ones can", c do
    alias Atoll.Accounts.AppPasswords
    {:ok, app} = AppPasswords.create(c.pair.access_jwt, %{"name" => "standard"})
    {:ok, pair} = Sessions.create(@did, app.password)
    limited = %{c | pair: pair}
    assert legacy(limited) |> get(@path) |> json_response(200)
    chat = "/xrpc/chat.bsky.convo.listConvos"
    assert legacy(limited) |> get(chat) |> json_response(403)

    assert legacy(limited)
           |> post("/xrpc/com.atproto.server.createAccount", "{}")
           |> json_response(403)

    {:ok, app} =
      AppPasswords.create(c.pair.access_jwt, %{"name" => "privileged", "privileged" => true})

    {:ok, pair} = Sessions.create(@did, app.password)
    assert legacy(%{c | pair: pair}) |> get(chat) |> json_response(200)
  end

  test "transitional OAuth chat delegation still requires the separate chat scope", c do
    chat = "/xrpc/chat.bsky.convo.listConvos"
    client = OAuthFixture.grant(c.pair, "atproto transition:generic")
    assert oauth(client) |> get(@path) |> json_response(200)
    assert oauth(client, chat) |> get(chat) |> json_response(403)
    client = OAuthFixture.grant(c.pair, "atproto transition:generic transition:chat.bsky")
    assert oauth(client, chat) |> get(chat) |> json_response(200)
  end

  test "legacy source revocation during resolution prevents signing", c do
    configure(fn _ -> flunk("revoked session must not send") end, fn ->
      assert {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)
    end)

    assert legacy(c) |> get(@path) |> json_response(401)
  end

  test "inactive callers and protected methods never resolve a destination", c do
    configure(fn _ -> flunk("must not send") end, fn -> flunk("must not resolve") end)
    assert c.conn |> put_req_header("atproto-proxy", @aud) |> get(@path) |> json_response(401)
    assert legacy(c) |> get("/xrpc/com.atproto.server.getSession") |> json_response(400)
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert legacy(c) |> get(@path) |> json_response(400)
    assert legacy(c) |> post("/xrpc/com.atproto.server.createAccount", "{}") |> json_response(403)
  end

  test "default AppView proxies unknown app.bsky methods while keeping local routes local", c do
    Application.put_env(:atoll, :appview_proxy, @aud)
    request = legacy(c) |> delete_req_header("atproto-proxy")
    assert request |> get(@path) |> json_response(200) == %{"proxied" => true}
    configure(fn _ -> flunk("must remain local") end, fn -> flunk("must remain local") end)
    assert request |> get("/xrpc/com.atproto.server.describeServer") |> json_response(200)
    assert request |> get("/xrpc/com.example.unknown") |> json_response(501)
    Application.delete_env(:atoll, :appview_proxy)
    assert request |> get(@path) |> json_response(501)
  end

  test "default moderation services route reports and ozone methods without a proxy header",
       c do
    report = "/xrpc/com.atproto.moderation.createReport"
    ozone = "/xrpc/tools.ozone.moderation.queryStatuses"
    request = legacy(c) |> delete_req_header("atproto-proxy")
    assert request |> post(report, "{}") |> json_response(501)

    Application.put_env(:atoll, :mod_service_proxy, @aud)
    assert request |> post(report, "{}") |> json_response(200) == %{"proxied" => true}
    assert request |> get(ozone) |> json_response(200) == %{"proxied" => true}
    assert request |> get(@path) |> json_response(501)

    Application.delete_env(:atoll, :mod_service_proxy)
    Application.put_env(:atoll, :report_service_proxy, @aud)
    assert request |> post(report, "{}") |> json_response(200) == %{"proxied" => true}
    assert request |> get(ozone) |> json_response(501)

    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert request |> post(report, "{}") |> json_response(400)
  end

  test "getFeed mints skeleton tokens for the published feed generator", c do
    feed = "at://did:plc:feedowner1234567890abcdef/app.bsky.feed.generator/cool"
    feedgen = "did:web:feedgen.example.com"
    path = "/xrpc/app.bsky.feed.getFeed"
    query = "?feed=" <> URI.encode_www_form(feed)

    stub = fn generator ->
      configure(fn conn ->
        case conn.request_path do
          "/xrpc/com.atproto.repo.getRecord" ->
            assert conn.method == "GET"
            assert get_req_header(conn, "authorization") == []

            assert URI.decode_query(conn.query_string) == %{
                     "repo" => "did:plc:feedowner1234567890abcdef",
                     "collection" => "app.bsky.feed.generator",
                     "rkey" => "cool"
                   }

            Req.Test.json(conn, %{"uri" => feed, "value" => generator})

          ^path ->
            claims(conn, c.key, "app.bsky.feed.getFeedSkeleton", feedgen)
            Req.Test.json(conn, %{feed: []})
        end
      end)
    end

    stub.(%{"$type" => "app.bsky.feed.generator", "did" => feedgen})
    assert legacy(c) |> get(path <> query) |> json_response(200) == %{"feed" => []}

    assert legacy(c) |> get(path) |> json_response(400) == %{
             "error" => "UnknownFeed",
             "message" => "could not resolve feed did"
           }

    assert legacy(c) |> get(path <> "?feed=not-a-uri") |> json_response(400)
    stub.(%{"$type" => "app.bsky.feed.generator"})

    assert legacy(c) |> get(path <> query) |> json_response(400) == %{
             "error" => "UnknownFeed",
             "message" => "could not resolve feed did"
           }

    stub.(%{"$type" => "app.bsky.feed.generator", "did" => feedgen})

    partial =
      OAuthFixture.grant(
        c.pair,
        "atproto rpc:app.bsky.feed.getFeed?aud=#{URI.encode_www_form(@aud)}"
      )

    assert oauth(partial, path, "GET") |> get(path <> query) |> json_response(403) == %{
             "error" => "insufficient_scope"
           }

    full =
      OAuthFixture.grant(
        c.pair,
        "atproto rpc:app.bsky.feed.getFeed?aud=#{URI.encode_www_form(@aud)} " <>
          "rpc:app.bsky.feed.getFeedSkeleton?aud=#{URI.encode_www_form(@aud)}"
      )

    assert oauth(full, path, "GET") |> get(path <> query) |> json_response(200) == %{
             "feed" => []
           }
  end

  test "push registration binds tokens to the body service DID", c do
    Application.put_env(:atoll, :appview_proxy, @aud)
    notif = "did:web:notif.example.com"
    path = "/xrpc/app.bsky.notification.registerPush"
    body = %{"serviceDid" => notif, "platform" => "web", "token" => "t", "appId" => "app"}

    stub = fn upstream ->
      Application.put_env(:atoll, :proxy_options,
        resolver: [
          lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
          request:
            Req.new(
              plug: fn conn ->
                if "notif.example.com" in [conn.host | get_req_header(conn, "host")] do
                  Req.Test.json(conn, %{
                    "id" => notif,
                    "service" => [
                      %{
                        "id" => "#bsky_notif",
                        "type" => "BskyNotificationService",
                        "serviceEndpoint" => "https://push.example.com"
                      }
                    ]
                  })
                else
                  Req.Test.json(conn, %{
                    "id" => @service,
                    "service" => [
                      %{
                        "id" => "#bsky_appview",
                        "type" => "BskyAppView",
                        "serviceEndpoint" => "https://api.example.com"
                      }
                    ]
                  })
                end
              end
            )
        ],
        lookup: fn
          "push.example.com" -> {:ok, {2, 2, 2, 2}}
          "api.example.com" -> {:ok, {1, 1, 1, 1}}
        end,
        request: Req.new(plug: upstream)
      )
    end

    stub.(fn conn ->
      claims(conn, c.key, "app.bsky.notification.registerPush", notif)
      assert conn.host == "2.2.2.2"
      assert {:ok, bytes, conn} = read_body(conn)
      assert Jason.decode!(bytes)["serviceDid"] == notif
      send_resp(conn, 200, "")
    end)

    request = legacy(c) |> delete_req_header("atproto-proxy")
    assert request |> post(path, Jason.encode!(body)) |> response(200) == ""

    stub.(fn conn ->
      claims(conn, c.key, "app.bsky.notification.registerPush", @service)
      assert conn.host == "1.1.1.1"
      send_resp(conn, 200, "")
    end)

    assert request
           |> post(path, Jason.encode!(%{body | "serviceDid" => @service}))
           |> response(200) == ""

    assert request |> post(path, Jason.encode!(%{"platform" => "web"})) |> json_response(400)
    assert request |> post(path, "not json") |> json_response(400)

    stub.(fn conn ->
      claims(conn, c.key, "app.bsky.notification.registerPush", notif)
      send_resp(conn, 200, "")
    end)

    scoped =
      OAuthFixture.grant(
        c.pair,
        "atproto rpc:app.bsky.notification.registerPush?aud=#{URI.encode_www_form(notif <> "#bsky_notif")}"
      )

    assert OAuthFixture.conn(scoped, path)
           |> post(path, Jason.encode!(body))
           |> response(200) == ""

    base = OAuthFixture.grant(c.pair, "atproto")

    assert OAuthFixture.conn(base, path)
           |> post(path, Jason.encode!(body))
           |> json_response(403) == %{"error" => "insufficient_scope"}
  end

  test "preflight needs no authentication or resolution and allows only GET and POST", c do
    configure(fn _ -> flunk("must not send") end, fn -> flunk("must not resolve") end)

    for method <- ["GET", "POST"] do
      result =
        c.conn
        |> put_req_header("origin", "https://app.example.com")
        |> put_req_header("access-control-request-method", method)
        |> put_req_header("access-control-request-headers", "authorization, dpop, atproto-proxy")
        |> options(@path)

      assert result.status == 204
      assert get_resp_header(result, "access-control-allow-methods") == [method]
    end

    assert legacy(c) |> delete(@path) |> json_response(405)
    assert legacy(c) |> get("/xrpc/app.bsky.feed.%67etTimeline") |> json_response(400)

    assert legacy(c)
           |> put_req_header("atproto-proxy", @service)
           |> get(@path)
           |> json_response(400)

    dup = %{legacy(c) | req_headers: [{"atproto-proxy", @aud} | legacy(c).req_headers]}
    assert dup |> get(@path) |> json_response(400)
  end

  test "proxied record writes retain aggregate limits when local record limits are disabled", c do
    Application.put_env(:atoll, :record_write_rate_limit, 0)
    Application.put_env(:atoll, :xrpc_rate_limit, 1)
    route = "/xrpc/com.atproto.repo.createRecord"
    assert legacy(c) |> post(route, "{}") |> json_response(200)

    assert legacy(c) |> post(route, "{}") |> json_response(429) == %{
             "error" => "RateLimitExceeded",
             "message" => "Too many XRPC requests."
           }
  end

  test "oversized OAuth bodies consume the proof without resolving or forwarding", c do
    client = OAuthFixture.grant(c.pair, @scope)
    configure(fn _ -> flunk("must not send") end, fn -> flunk("must not resolve") end)
    request = oauth(client, @path, "POST")

    assert request
           |> post(@path, String.duplicate("x", 2 * 1024 * 1024 + 1))
           |> json_response(413)

    assert request |> post(@path, "{}") |> json_response(401) == %{
             "error" => "invalid_dpop_proof"
           }
  end

  test "upstream errors are preserved, redirects are rejected and oversized replies fail", c do
    configure(fn conn ->
      conn |> put_resp_header("retry-after", "20") |> send_resp(429, "slow down")
    end)

    result = legacy(c) |> get(@path)
    assert result.status == 429
    assert result.resp_body == "slow down"
    assert get_resp_header(result, "retry-after") == ["20"]

    configure(fn conn ->
      conn |> put_resp_header("location", "http://127.0.0.1") |> send_resp(302, "")
    end)

    assert legacy(c) |> get(@path) |> json_response(502)
    configure(fn conn -> send_resp(conn, 200, String.duplicate("x", 8 * 1024 * 1024 + 1)) end)
    assert legacy(c) |> get(@path) |> json_response(502)
  end

  test "default AppView configuration validates scalar service references" do
    assert AtollWeb.ProxyPlug.appview_from_env!(@aud) == @aud
    for value <- [nil, ""], do: assert(is_nil(AtollWeb.ProxyPlug.appview_from_env!(value)))

    for value <- [@service, "https://appview.example.com", @aud <> "#more"] do
      assert_raise ArgumentError, fn -> AtollWeb.ProxyPlug.appview_from_env!(value) end
    end
  end

  test "proof and session admission precede the preparation callback and reject caller transactions",
       c do
    alias Atoll.OAuth.Resource
    alias Atoll.Accounts.ServiceAuth
    client = OAuthFixture.grant(c.pair, @scope)
    prepare = fn -> flunk("must not read a body or resolve a destination") end
    url = AtollWeb.Endpoint.url() <> @path

    assert {:error, _} =
             Resource.with_proxy(client.token, ["bad"], "POST", url, @aud, @nsid, prepare)

    assert {:error, :invalid_token} = ServiceAuth.with_proxy("bad", @aud, @nsid, prepare)
    proof = OAuthFixture.proof(client, @path, "GET")

    assert {:ok, {:error, :oauth_resource_inside_transaction}} =
             Repo.transaction(fn ->
               Resource.with_proxy(client.token, [proof], "GET", url, @aud, @nsid, prepare)
             end)

    assert {:ok, {:error, :proxy_inside_transaction}} =
             Repo.transaction(fn ->
               ServiceAuth.with_proxy(c.pair.access_jwt, @aud, @nsid, prepare)
             end)
  end

  test "missing signing keys fail locally without sending to the service", c do
    configure(fn _ -> flunk("must not send") end)
    Application.delete_env(:atoll, :key_encryption_key)
    assert legacy(c) |> get(@path) |> json_response(503)
  end
end
