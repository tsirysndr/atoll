defmodule AtollWeb.PasswordResetControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.Accounts.{Credentials, PasswordReset, Profile, Sessions}
  alias Atoll.{Repo, Repositories, SigningKey}
  @did "did:web:password.example.com"
  @request "/xrpc/com.atproto.server.requestPasswordReset"
  @reset "/xrpc/com.atproto.server.resetPassword"
  @old "old password for recovery"
  @new "new password after recovery"

  setup %{conn: conn} do
    previous =
      Map.new(
        [:session_signing_key, :email_worker, :email_delivery_options],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    Application.put_env(:atoll, :session_signing_key, :binary.copy(<<33>>, 32))

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
    Repo.insert!(%Profile{did: @did, handle: "password.example.com", email: "owner@example.com"})
    {:ok, _} = Credentials.create(@did, @old)
    {:ok, pair} = Sessions.create(@did, @old)
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 47, div(id, 256), rem(id, 256)}}, pair: pair}
  end

  test "recovery replaces password, revokes all account sessions, and prevents stale-proof login",
       c do
    {:ok, second} = Sessions.create(@did, @old)

    {:ok, app} =
      Atoll.Accounts.AppPasswords.create(c.pair.access_jwt, %{"name" => "recovery-test"})

    {:ok, app_session} = Sessions.create(@did, app.password)
    other = "did:web:other-password.example.com"
    {:ok, _} = Repositories.create(other, SigningKey.generate())
    {:ok, _} = Credentials.create(other, @old)
    {:ok, unaffected} = Sessions.create(other, @old)
    {:ok, digest} = Credentials.verified_digest(@did, @old)
    code = request_code(c)
    profile = Repo.get!(Profile, @did)
    assert byte_size(profile.password_reset_digest) == 32
    refute profile.password_reset_digest == code
    assert response(reset(c, code, @new), 200) == ""
    assert {:error, :invalid_credentials} = Sessions.create(@did, @old)
    assert {:error, :invalid_credentials} = Sessions.create(@did, app.password)
    assert {:error, :invalid_token} = Sessions.authenticate(app_session.access_jwt)
    refute Repo.exists?(Atoll.Accounts.AppPassword)

    assert {:error, :invalid_credentials} =
             Sessions.create_for_account(@did, credential_digest: digest)

    for pair <- [c.pair, second] do
      assert {:error, :invalid_token} = Sessions.authenticate_management(pair.access_jwt)
      assert {:error, :invalid_token} = Sessions.refresh(pair.refresh_jwt)
    end

    assert {:ok, _} = Sessions.authenticate(unaffected.access_jwt)
    assert {:ok, _} = Sessions.create(@did, @new)
    assert is_nil(Repo.get!(Profile, @did).password_reset_digest)
    assert json_response(reset(c, code, "another new password"), 400)["error"] == "InvalidToken"
  end

  test "expired, replaced and invalid tokens cannot change credentials", c do
    old = request_code(c)
    assert response(request(c, "owner@example.com"), 200) == ""
    change(password_reset_expires_at: System.system_time(:second) - 1)
    assert json_response(reset(c, old, @new), 400)["error"] == "ExpiredToken"
    change(password_reset_requested_at: System.system_time(:second) - 61)
    code = request_code(c)
    refute code == old
    assert response(reset(c, old, @new), 400)
    assert response(reset(c, String.duplicate("x", 32), @new), 400)
    assert response(reset(c, code, "short"), 400)
    assert {:ok, _} = Sessions.create(@did, @old)
    assert response(reset(c, code, @new), 200) == ""
  end

  test "unknown, throttled, unavailable and suspended accounts return the same request response",
       c do
    assert response(request(c, "unknown@example.com"), 200) == ""
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, "private provider failure"))
    assert response(request(c, "owner@example.com"), 200) == ""
    assert response(request(c, "owner@example.com"), 200) == ""
    {:ok, _} = Repositories.set_status(@did, :suspended)
    assert response(request(c, "owner@example.com"), 200) == ""
    assert {:ok, _} = Credentials.verify(@did, @old)
  end

  test "email change invalidates recovery code and recovery clears email-management codes", c do
    old = request_code(c)

    assert {:ok, _} =
             Atoll.Accounts.EmailUpdate.update(c.pair.access_jwt, %{
               "email" => "changed@example.com"
             })

    assert response(reset(c, old, @new), 400)

    change(
      email: "owner@example.com",
      password_reset_requested_at: System.system_time(:second) - 61,
      email_update_digest: :crypto.hash(:sha256, "update"),
      email_update_expires_at: System.system_time(:second) + 900,
      email_update_requested_at: System.system_time(:second),
      email_confirmation_digest: :crypto.hash(:sha256, "confirm"),
      email_confirmation_expires_at: System.system_time(:second) + 900,
      email_confirmation_requested_at: System.system_time(:second)
    )

    code = request_code(c)
    assert response(reset(c, code, @new), 200) == ""

    assert %Profile{email_update_digest: nil, email_confirmation_digest: nil} =
             Repo.get!(Profile, @did)
  end

  test "deactivated recovery works; suspended account cannot redeem an existing code", c do
    code = request_code(c)
    {:ok, _} = Repositories.set_status(@did, :suspended)
    assert response(reset(c, code, @new), 400)
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert response(reset(c, code, @new), 200) == ""
    assert {:ok, %{status: :deactivated}} = Sessions.create(@did, @new)
  end

  test "bounded request methods and missing delivery configuration", c do
    assert response(get(c.conn, @request), 405)
    assert response(get(c.conn, @reset), 405)
    assert response(request(c, "bad"), 400)
    assert response(reset(c, "bad", @new), 400)

    assert response(
             c.conn
             |> put_req_header("content-type", "application/json")
             |> post(@request, String.duplicate("x", 4097)),
             413
           )

    Application.delete_env(:atoll, :email_worker)

    assert {:error, :email_not_configured} =
             PasswordReset.request(%{"email" => "owner@example.com"})

    assert response(request(c, "owner@example.com"), 503)
    assert response(request(c, "unknown@example.com"), 503)
  end

  defp request_code(c) do
    parent = self()

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)
      assert message["to"] == "owner@example.com"
      [_, code] = Regex.run(~r/code is: ([A-Za-z0-9_-]{32})/, message["text"])
      send(parent, {:code, code})
      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert response(request(c, "OWNER@example.com"), 200) == ""
    assert_receive {:code, code}
    code
  end

  defp request(c, email), do: json_post(c.conn, @request, %{email: email})

  defp reset(c, token, password),
    do: json_post(c.conn, @reset, %{token: token, password: password})

  defp json_post(conn, route, params),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(route, Jason.encode!(params))

  defp change(attrs),
    do: Repo.get!(Profile, @did) |> Ecto.Changeset.change(attrs) |> Repo.update!()
end
