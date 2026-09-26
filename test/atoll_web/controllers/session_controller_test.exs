defmodule AtollWeb.SessionControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repositories, SigningKey}
  alias Atoll.Accounts.{Credentials, Sessions}
  @did "did:plc:httpsessions"
  @password "HTTP session password"
  @create "/xrpc/com.atproto.server.createSession"
  @get "/xrpc/com.atproto.server.getSession"
  @refresh "/xrpc/com.atproto.server.refreshSession"
  @delete "/xrpc/com.atproto.server.deleteSession"

  setup %{conn: conn} do
    previous = Application.get_env(:atoll, :session_signing_key)
    Application.put_env(:atoll, :session_signing_key, :binary.copy(<<12>>, 32))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:atoll, :session_signing_key, previous),
        else: Application.delete_env(:atoll, :session_signing_key)
    end)

    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    {:ok, _} = Credentials.create(@did, @password)
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 10, div(id, 256), rem(id, 256)}}}
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

    assert %{"error" => "InvalidRequest"} =
             login(conn, %{"identifier" => "alice.example.com"}) |> json_response(400)

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

    assert %{"error" => "RepoDeactivated"} =
             conn |> bearer(pair["accessJwt"]) |> get(@get) |> json_response(400)

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

  defp login(conn, overrides \\ %{}) do
    body = Map.merge(%{"identifier" => @did, "password" => @password}, overrides)

    conn
    |> put_req_header("content-type", "application/json")
    |> post(@create, Jason.encode!(body))
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
