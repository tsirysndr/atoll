defmodule AtollWeb.EmailConfirmationControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.Accounts.{Credentials, Profile, Sessions}
  alias Atoll.{Repo, Repositories, SigningKey}
  @did "did:web:email.example.com"
  @request "/xrpc/com.atproto.server.requestEmailConfirmation"
  @confirm "/xrpc/com.atproto.server.confirmEmail"

  setup %{conn: conn} do
    keys = [:session_signing_key, :email_worker, :email_delivery_options]
    previous = Map.new(keys, &{&1, Application.fetch_env(:atoll, &1)})
    Application.put_env(:atoll, :session_signing_key, :binary.copy(<<31>>, 32))

    Application.put_env(:atoll, :email_worker,
      url: "https://worker.example.com/send",
      token: "secret"
    )

    Application.put_env(:atoll, :email_delivery_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    Repo.insert!(%Profile{did: @did, handle: "email.example.com", email: "owner@example.com"})
    {:ok, _} = Credentials.create(@did, "email confirmation password")
    {:ok, pair} = Sessions.create(@did, "email confirmation password")
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 45, div(id, 256), rem(id, 256)}}, pair: pair}
  end

  test "delivers through Worker, confirms once, and reports confirmation in sessions", c do
    code = request_code(c)
    profile = Repo.get!(Profile, @did)
    assert byte_size(profile.email_confirmation_digest) == 32
    refute profile.email_confirmation_digest == code
    assert is_nil(profile.email_confirmed_at)
    assert json_response(confirm(c, "wrong@example.com", code), 400)["error"] == "InvalidEmail"

    assert json_response(confirm(c, "owner@example.com", String.duplicate("x", 32)), 400)["error"] ==
             "InvalidToken"

    assert response(confirm(c, "OWNER@example.com", code), 200) == ""

    assert %Profile{email_confirmation_digest: nil, email_confirmed_at: %DateTime{}} =
             Repo.get!(Profile, @did)

    assert json_response(confirm(c, "owner@example.com", code), 400)["error"] == "InvalidToken"

    session =
      c.conn |> auth(c) |> get("/xrpc/com.atproto.server.getSession") |> json_response(200)

    assert session["email"] == "owner@example.com"
    assert session["emailConfirmed"] == true
    # Already-confirmed requests are idempotent and send no further email.
    assert response(c.conn |> auth(c) |> post(@request), 200) == ""
  end

  test "persistent cooldown, expiration, and token replacement", c do
    old = request_code(c)
    assert json_response(c.conn |> auth(c) |> post(@request), 429)["error"] == "RateLimitExceeded"
    update_profile(email_confirmation_expires_at: System.system_time(:second) - 1)
    assert json_response(confirm(c, "owner@example.com", old), 400)["error"] == "ExpiredToken"
    update_profile(email_confirmation_requested_at: System.system_time(:second) - 61)
    new = request_code(c)
    refute old == new
    assert json_response(confirm(c, "owner@example.com", old), 400)["error"] == "InvalidToken"
    assert response(confirm(c, "owner@example.com", new), 200) == ""
  end

  test "requires a live management session and enforces method and body bounds", c do
    assert json_response(post(c.conn, @request), 401)["error"] == "AuthRequired"
    assert response(c.conn |> auth(c) |> get(@request), 405)

    assert response(
             c.conn
             |> auth(c)
             |> put_req_header("content-type", "application/json")
             |> post(@confirm, String.duplicate("x", 4097)),
             413
           )

    assert response(confirm(c, "owner@example.com", "short"), 400)
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    code = request_code(c)
    assert response(confirm(c, "owner@example.com", code), 200) == ""
    {:ok, _} = Sessions.revoke(c.pair.refresh_jwt)
    assert response(c.conn |> auth(c) |> post(@request), 401)
  end

  test "delivery failures never confirm and retain cooldown against repeated failures", c do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "private error") end)
    result = c.conn |> auth(c) |> post(@request)
    assert json_response(result, 503)["error"] == "ServiceUnavailable"
    refute result.resp_body =~ "private"
    assert is_nil(Repo.get!(Profile, @did).email_confirmed_at)
    assert response(c.conn |> auth(c) |> post(@request), 429)
  end

  test "code cannot confirm a changed address or a different account", c do
    code = request_code(c)
    update_profile(email: "changed@example.com")
    assert response(confirm(c, "changed@example.com", code), 400)
    assert response(confirm(c, "owner@example.com", code), 400)
    other = "did:web:other-email.example.com"
    {:ok, _} = Repositories.create(other, SigningKey.generate())

    Repo.insert!(%Profile{
      did: other,
      handle: "other-email.example.com",
      email: "owner@example.com"
    })

    {:ok, _} = Credentials.create(other, "other email password")
    {:ok, pair} = Sessions.create(other, "other email password")
    assert response(confirm(%{c | pair: pair}, "owner@example.com", code), 400)
  end

  defp request_code(c) do
    parent = self()

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      email = Jason.decode!(body)
      assert email["to"] == "owner@example.com"
      [_, code] = Regex.run(~r/code is: ([A-Za-z0-9_-]{32})/, email["text"])
      send(parent, {:code, code})
      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert response(c.conn |> auth(c) |> post(@request), 200) == ""
    assert_receive {:code, code}
    code
  end

  defp update_profile(attrs),
    do: Repo.get!(Profile, @did) |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp auth(conn, c), do: put_req_header(conn, "authorization", "Bearer " <> c.pair.access_jwt)

  defp confirm(c, email, code),
    do:
      c.conn
      |> auth(c)
      |> put_req_header("content-type", "application/json")
      |> post(@confirm, Jason.encode!(%{email: email, token: code}))
end
