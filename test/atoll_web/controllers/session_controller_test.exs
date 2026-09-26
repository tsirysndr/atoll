defmodule AtollWeb.SessionControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repositories, SigningKey}
  alias Atoll.Accounts.{Credentials, Sessions}
  @did "did:web:alice.example.com"
  @password "HTTP session password"
  @create "/xrpc/com.atproto.server.createSession"
  @get "/xrpc/com.atproto.server.getSession"
  @refresh "/xrpc/com.atproto.server.refreshSession"
  @delete "/xrpc/com.atproto.server.deleteSession"

  setup %{conn: conn} do
    resolution = Application.fetch_env(:atoll, :identity_resolution_options)
    previous = Application.get_env(:atoll, :session_signing_key)
    Application.put_env(:atoll, :session_signing_key, :binary.copy(<<12>>, 32))

    on_exit(fn ->
      case resolution do
        {:ok, value} -> Application.put_env(:atoll, :identity_resolution_options, value)
        :error -> Application.delete_env(:atoll, :identity_resolution_options)
      end

      if previous,
        do: Application.put_env(:atoll, :session_signing_key, previous),
        else: Application.delete_env(:atoll, :session_signing_key)
    end)

    {:ok, head} = Repositories.create(@did, SigningKey.generate())
    {:ok, _} = Credentials.create(@did, @password)
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 10, div(id, 256), rem(id, 256)}}, head: head}
  end

  test "email login normalizes identifiers and follows changes without sending mail", %{
    conn: conn
  } do
    profile =
      Atoll.Repo.insert!(%Atoll.Accounts.Profile{
        did: @did,
        handle: "alice.example.com",
        email: "alice@example.com"
      })

    pair = login(conn, %{"identifier" => "ALICE@example.com"}) |> json_response(200)
    assert pair["did"] == @did
    assert pair["email"] == "alice@example.com"
    assert pair["emailConfirmed"] == false
    assert pair["handle"] == "alice.example.com"
    assert {:ok, _} = Sessions.authenticate(pair["accessJwt"])

    wrong =
      login(conn, %{"identifier" => "alice@example.com", "password" => "incorrect password"})
      |> json_response(401)

    unknown = login(conn, %{"identifier" => "unknown@example.com"}) |> json_response(401)
    assert wrong == unknown

    profile
    |> Ecto.Changeset.change(email: "new@example.com", email_confirmed_at: DateTime.utc_now())
    |> Atoll.Repo.update!()

    assert login(conn, %{"identifier" => "alice@example.com"}) |> response(401)
    changed = login(conn, %{"identifier" => "NEW@example.com"}) |> json_response(200)
    assert changed["emailConfirmed"]
    {:ok, _} = Repositories.set_status(@did, :deactivated)

    assert %{"status" => "deactivated", "active" => false} =
             login(conn, %{"identifier" => "new@example.com"}) |> json_response(200)

    {:ok, _} = Repositories.set_status(@did, :takendown)

    assert %{"error" => "AccountTakedown"} =
             login(conn, %{"identifier" => "new@example.com"}) |> json_response(400)
  end

  test "account session cap returns a protocol error and revocation frees a slot", %{conn: conn} do
    prior = Application.fetch_env(:atoll, :session_max_count)
    Application.put_env(:atoll, :session_max_count, 1)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:atoll, :session_max_count, value)
        :error -> Application.delete_env(:atoll, :session_max_count)
      end
    end)

    pair = login(conn) |> json_response(200)
    assert %{"error" => "RateLimitExceeded"} = login(conn) |> json_response(429)
    assert conn |> bearer(pair["refreshJwt"]) |> post(@delete) |> response(200) == ""
    assert login(conn) |> json_response(200)
  end

  test "creates, inspects, refreshes and deletes a session", %{conn: conn} do
    created = login(conn)
    assert get_resp_header(created, "cache-control") == ["no-store"]
    pair = json_response(created, 200)
    assert pair["did"] == @did
    assert pair["handle"] == "handle.invalid"
    assert pair["active"]
    shown = conn |> bearer(pair["accessJwt"]) |> get(@get) |> json_response(200)
    assert shown == %{"did" => @did, "handle" => "handle.invalid", "active" => true}
    next = conn |> bearer(pair["refreshJwt"]) |> post(@refresh) |> json_response(200)
    refute next["refreshJwt"] == pair["refreshJwt"]

    assert %{"error" => "InvalidToken"} =
             conn |> bearer(pair["refreshJwt"]) |> post(@refresh) |> json_response(401)

    deleted = conn |> bearer(next["refreshJwt"]) |> post(@delete)
    assert response(deleted, 200) == ""
    assert get_resp_header(deleted, "cache-control") == ["no-store"]

    assert %{"error" => "InvalidToken"} =
             conn |> bearer(pair["accessJwt"]) |> get(@get) |> json_response(401)
  end

  test "requires bearer tokens of the correct type and rejects duplicate headers", %{conn: conn} do
    pair = login(conn) |> json_response(200)
    assert %{"error" => "AuthRequired"} = conn |> get(@get) |> json_response(401)

    assert %{"error" => "InvalidToken"} =
             conn |> bearer(pair["refreshJwt"]) |> get(@get) |> json_response(401)

    for path <- [@refresh, @delete] do
      assert %{"error" => "InvalidToken"} =
               conn |> bearer(pair["accessJwt"]) |> post(path) |> json_response(401)
    end

    duplicate = %{
      conn
      | req_headers: [
          {"authorization", "Bearer " <> pair["accessJwt"]},
          {"authorization", "Bearer " <> pair["accessJwt"]}
        ]
    }

    assert %{"error" => "InvalidToken"} = duplicate |> get(@get) |> json_response(401)

    assert %{"error" => "AuthRequired"} =
             conn |> get(@get, %{accessJwt: pair["accessJwt"]}) |> json_response(401)
  end

  test "does not read credentials or signing options from query parameters", %{conn: conn} do
    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(@create <> "?identifier=" <> @did <> "&password=ignored", "{}")

    assert %{"error" => "InvalidRequest"} = json_response(response, 400)

    assert %{"error" => "AuthRequired"} =
             login(conn, %{"password" => "incorrect password"}) |> json_response(401)

    assert %{"error" => "AuthRequired"} =
             login(conn, %{"identifier" => "did:plc:missing"}) |> json_response(401)

    assert %{"error" => "AuthRequired"} =
             login(conn, %{"identifier" => "alice@example.com"}) |> json_response(401)

    for override <- [
          %{"password" => []},
          %{"allowTakendown" => true},
          %{"authFactorToken" => "x"}
        ] do
      assert %{"error" => "InvalidRequest"} = login(conn, override) |> json_response(400)
    end

    Application.delete_env(:atoll, :session_signing_key)

    assert %{"error" => "ServiceUnavailable"} =
             login(conn, %{"secret" => String.duplicate("x", 32)}) |> json_response(503)
  end

  test "enforces methods, JSON content and bounded bodies before normal parsing", %{conn: conn} do
    for method <- [:get, :head, :put] do
      result = dispatch(conn, @endpoint, method, @create, nil)
      assert result.status == 405
      assert get_resp_header(result, "allow") == ["POST"]
    end

    assert %{"error" => "InvalidRequest"} =
             conn
             |> put_req_header("content-type", "text/plain")
             |> post(@create, "raw")
             |> json_response(415)

    for {body, status} <- [{"{", 400}, {String.duplicate("x", 5000), 413}, {"[]", 400}] do
      result = conn |> put_req_header("content-type", "application/json") |> post(@create, body)
      assert %{"error" => "InvalidRequest"} = json_response(result, status)
      assert get_resp_header(result, "cache-control") == ["no-store"]
    end

    assert %{"error" => "InvalidRequest"} =
             conn
             |> put_req_header("content-type", "text/plain")
             |> post(@refresh, "unexpected")
             |> json_response(400)
  end

  test "limits login attempts by direct peer and ignores forwarded IP headers", %{conn: conn} do
    for n <- 1..20 do
      result =
        conn
        |> put_req_header("x-forwarded-for", "192.0.2.#{n}")
        |> login(%{"password" => "incorrect password"})

      assert result.status == 401
    end

    limited = login(conn)
    assert %{"error" => "RateLimitExceeded"} = json_response(limited, 429)
    assert [_] = get_resp_header(limited, "retry-after")
    assert get_resp_header(limited, "cache-control") == ["no-store"]

    encoded =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/xrpc/com.atproto.server.%63reateSession",
        Jason.encode!(%{identifier: @did, password: @password})
      )

    assert %{"error" => "RateLimitExceeded"} = json_response(encoded, 429)
  end

  test "reports expired tokens and allows revocation after deactivation", %{conn: conn} do
    {:ok, expired} = Sessions.create(@did, @password, now: System.system_time(:second) - 7200)

    assert %{"error" => "ExpiredToken"} =
             conn |> bearer(expired.access_jwt) |> get(@get) |> json_response(401)

    pair = login(conn) |> json_response(200)
    {:ok, _} = Repositories.set_status(@did, :deactivated)

    assert %{"active" => false, "status" => "deactivated"} =
             conn |> bearer(pair["accessJwt"]) |> get(@get) |> json_response(200)

    inactive = login(conn) |> json_response(200)
    assert inactive["active"] == false
    assert inactive["status"] == "deactivated"

    assert %{"active" => false, "status" => "deactivated"} =
             conn |> bearer(inactive["refreshJwt"]) |> post(@refresh) |> json_response(200)

    assert response(conn |> bearer(pair["refreshJwt"]) |> post(@delete), 200) == ""
  end

  test "returns the observed handle and the session-specific takedown error", %{conn: conn} do
    Atoll.Repo.insert!(%Atoll.Identity.Observation{
      did: @did,
      handle: "alice.example.com",
      fingerprint: :binary.copy(<<0>>, 32)
    })

    pair = login(conn) |> json_response(200)
    assert pair["handle"] == "alice.example.com"
    {:ok, _} = Repositories.set_status(@did, :takendown)
    assert %{"error" => "AccountTakedown"} = login(conn) |> json_response(400)

    assert %{"error" => "AccountTakedown"} =
             conn |> bearer(pair["refreshJwt"]) |> post(@refresh) |> json_response(400)
  end

  test "logs in through a verified normalized handle and issues tokens for its DID", c do
    configure_handle(c)
    pair = login(c.conn, %{"identifier" => "Alice.Example.Com"}) |> json_response(200)
    assert pair["did"] == @did
    assert pair["handle"] == "alice.example.com"
    assert Sessions.authenticate(pair["accessJwt"]) == {:ok, %{did: @did}}

    assert %{"error" => "AuthRequired"} =
             login(c.conn, %{
               "identifier" => "alice.example.com",
               "password" => "incorrect password"
             })
             |> json_response(401)
  end

  test "rejects forward-only aliases, mismatched documents and unhosted identities", c do
    for {did, changes} <- [
          {@did, %{"alsoKnownAs" => ["at://someoneelse.example.com"]}},
          {@did, %{"id" => "did:web:someoneelse.example.com"}},
          {"did:web:missing.example.com", %{}}
        ] do
      configure_handle(c, did, changes)

      assert %{"error" => "AuthRequired"} =
               login(c.conn, %{"identifier" => "alice.example.com"}) |> json_response(401)
    end

    refute Atoll.Repo.exists?(Atoll.Accounts.Session)
  end

  test "validates input and rate limits before resolution; DID login bypasses resolution", c do
    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn _ -> flunk("unexpected lookup") end
    )

    assert %{"error" => "InvalidRequest"} =
             login(c.conn, %{"identifier" => "alice.example.com", "password" => []})
             |> json_response(400)

    assert login(c.conn) |> json_response(200) |> Map.fetch!("did") == @did
    for _ <- 1..20, do: Atoll.Accounts.SessionLimiter.check({:login, c.conn.remote_ip}, 20)

    assert %{"error" => "RateLimitExceeded"} =
             login(c.conn, %{"identifier" => "alice.example.com"}) |> json_response(429)
  end

  test "checks account availability after handle resolution", c do
    configure_handle(c)
    opts = Application.fetch_env!(:atoll, :identity_resolution_options)
    original = opts[:request].options.plug

    request =
      Req.new(
        plug: fn conn ->
          {:ok, _} = Repositories.set_status(@did, :suspended)
          original.(conn)
        end
      )

    Application.put_env(
      :atoll,
      :identity_resolution_options,
      Keyword.put(opts, :request, request)
    )

    assert %{"error" => "RepoSuspended"} =
             login(c.conn, %{"identifier" => "alice.example.com"}) |> json_response(400)

    refute Atoll.Repo.exists?(Atoll.Accounts.Session)
  end

  defp configure_handle(c, did \\ @did, changes \\ %{}) do
    {:ok, public} = Atoll.Multikey.encode(c.head.curve, c.head.public_key)

    document =
      Map.merge(
        %{
          "id" => did,
          "alsoKnownAs" => ["at://alice.example.com"],
          "verificationMethod" => [
            %{
              "id" => "#atproto",
              "controller" => did,
              "type" => "Multikey",
              "publicKeyMultibase" => public
            }
          ],
          "service" => [
            %{
              "id" => "#atproto_pds",
              "type" => "AtprotoPersonalDataServer",
              "serviceEndpoint" => "https://pds.example.com"
            }
          ]
        },
        changes
      )

    Application.put_env(:atoll, :identity_resolution_options,
      txt_lookup: fn name ->
        assert name == "_atproto.alice.example.com"
        [["did=" <> did]]
      end,
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      request:
        Req.new(
          plug: fn conn ->
            assert get_req_header(conn, "authorization") == []
            assert {:ok, "", conn} = Plug.Conn.read_body(conn)
            Req.Test.json(conn, document)
          end
        )
    )
  end

  defp login(conn, overrides \\ %{}) do
    body = Map.merge(%{"identifier" => @did, "password" => @password}, overrides)

    conn
    |> put_req_header("content-type", "application/json")
    |> post(@create, Jason.encode!(body))
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
