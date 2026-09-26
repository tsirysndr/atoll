defmodule AtollWeb.AdminInviteControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{AdminAuth, AppPasswords, Invite, Sessions}
  @single "/xrpc/com.atproto.server.createInviteCode"
  @bulk "/xrpc/com.atproto.server.createInviteCodes"
  @disable "/xrpc/com.atproto.admin.disableInviteCodes"
  @secret "an-independent-operator-secret-at-least-32-bytes"

  setup %{conn: conn} do
    previous =
      Map.new([:admin_password, :session_signing_key], &{&1, Application.fetch_env(:atoll, &1)})

    Application.put_env(:atoll, :admin_password, @secret)
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 57, div(id, 256), rem(id, 256)}}}
  end

  test "creates codes singly and in atomic per-account batches, then disables selected groups",
       c do
    did = "did:web:inviter.example.com"
    {:ok, _} = Repositories.create(did, SigningKey.generate())
    single = post_json(auth(c.conn), @single, %{useCount: 2}) |> json_response(200)
    assert Repo.get!(Invite, single["code"]).remaining == 2

    grouped =
      post_json(auth(c.conn), @bulk, %{codeCount: 2, useCount: 3, forAccounts: [did]})
      |> json_response(200)

    assert [%{"account" => ^did, "codes" => codes}] = grouped["codes"]
    assert length(codes) == 2
    for code <- codes, do: assert(Repo.get!(Invite, code).for_account == did)
    assert post_json(auth(c.conn), @disable, %{accounts: [did]}) |> response(200) == ""
    for code <- codes, do: assert(Repo.get!(Invite, code).disabled)
    refute Repo.get!(Invite, single["code"]).disabled
    assert post_json(auth(c.conn), @disable, %{codes: [single["code"]]}) |> response(200) == ""
    assert Repo.get!(Invite, single["code"]).disabled
    unowned = post_json(auth(c.conn), @bulk, %{codeCount: 1, useCount: 1}) |> json_response(200)
    assert [%{"account" => "admin", "codes" => [_]}] = unowned["codes"]
  end

  test "bulk validation and a missing later owner roll back the whole batch", c do
    did = "did:web:valid.example.com"
    {:ok, _} = Repositories.create(did, SigningKey.generate())

    assert post_json(auth(c.conn), @bulk, %{
             codeCount: 2,
             useCount: 1,
             forAccounts: [did, "did:web:missing.example.com"]
           })
           |> json_response(400)

    assert Repo.aggregate(Invite, :count) == 0

    for params <- [
          %{codeCount: 501, useCount: 1},
          %{codeCount: 251, useCount: 1, forAccounts: [did, "did:web:other.example.com"]},
          %{codeCount: 1, useCount: 0},
          %{codeCount: 1, useCount: 1, forAccounts: [did, did]},
          %{codeCount: 1, useCount: 1, forAccounts: nil},
          %{codeCount: 1, useCount: 1, extra: true}
        ] do
      assert post_json(auth(c.conn), @bulk, params) |> json_response(400)
    end

    assert post_json(auth(c.conn), @single, %{useCount: 1, extra: true}) |> json_response(400)
    assert post_json(auth(c.conn), @disable, %{codes: ["invalid"]}) |> json_response(400)
    assert Repo.aggregate(Invite, :count) == 0
  end

  test "rejects user sessions, app passwords, duplicate headers and malformed credentials", c do
    did = "did:web:account.example.com"
    {:ok, _} = Repositories.create(did, SigningKey.generate())
    {:ok, full} = Sessions.create_for_account(did)
    {:ok, app} = AppPasswords.create(full.access_jwt, %{"name" => "test"})
    {:ok, restricted} = Sessions.create(did, app.password)

    for authorization <- [
          nil,
          "Bearer " <> full.access_jwt,
          "Bearer " <> restricted.access_jwt,
          "Basic " <> Base.encode64("user:" <> @secret),
          "Basic " <> Base.encode64("admin:" <> String.duplicate("x", 32)),
          "Basic invalid",
          "Basic " <> String.duplicate("a", 2048)
        ] do
      conn =
        if authorization, do: put_req_header(c.conn, "authorization", authorization), else: c.conn

      result = post_json(conn, @single, %{useCount: 1})
      assert json_response(result, 401)["error"] == "AuthRequired"
      assert get_resp_header(result, "www-authenticate") != []
      assert get_resp_header(result, "cache-control") == ["no-store"]
    end

    header = "Basic " <> Base.encode64("admin:" <> @secret)
    assert {:error, :invalid_admin_credentials} = AdminAuth.authenticate([header, header])
    assert {:error, :invalid_admin_credentials} = AdminAuth.authenticate([<<255, 32, 97>>])
    assert Repo.aggregate(Invite, :count) == 0
  end

  test "authenticates before parsing and enforces method, media type, size and decoded paths",
       c do
    unauth = c.conn |> put_req_header("content-type", "application/json") |> post(@single, "{")
    assert json_response(unauth, 401)

    bad_json =
      auth(c.conn) |> put_req_header("content-type", "application/json") |> post(@single, "{")

    assert json_response(bad_json, 400)

    oversized =
      auth(c.conn)
      |> put_req_header("content-type", "application/json")
      |> post(@single, String.duplicate("x", 16_385))

    assert json_response(oversized, 413)

    assert auth(c.conn)
           |> put_req_header("content-type", "text/plain")
           |> post(@single, "body")
           |> json_response(415)

    method = auth(c.conn) |> get(@single)
    assert json_response(method, 405)
    assert get_resp_header(method, "allow") == ["POST"]

    assert post_json(c.conn, "/xrpc/com.atproto.server.%63reateInviteCode", %{useCount: 1})
           |> json_response(401)

    Application.delete_env(:atoll, :admin_password)
    assert post_json(auth(c.conn), @single, %{useCount: 1}) |> json_response(503)
  end

  test "rate limits failed authentication independently of forwarded client addresses", c do
    for _ <- 1..60 do
      assert post_json(c.conn, @single, %{useCount: 1}) |> json_response(401)
    end

    result =
      c.conn
      |> put_req_header("x-forwarded-for", "8.8.8.8")
      |> auth()
      |> post_json(@single, %{useCount: 1})

    assert json_response(result, 429)
    assert get_resp_header(result, "retry-after") != []
    assert Repo.aggregate(Invite, :count) == 0
  end

  test "validates operator secret settings without echoing their contents" do
    assert AdminAuth.password_from_env!(nil) == nil
    assert AdminAuth.password_from_env!(@secret) == @secret

    for secret <- ["", "short-secret", String.duplicate("x", 1025), @secret <> "\n"] do
      error = assert_raise RuntimeError, fn -> AdminAuth.password_from_env!(secret) end
      refute error.message =~ "short-secret"
      refute error.message =~ @secret
    end
  end

  defp auth(conn),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("admin:" <> @secret))

  defp post_json(conn, path, params),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(params))
end
