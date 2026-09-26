defmodule AtollWeb.AdminPasswordControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, Repositories, SigningKey}

  alias Atoll.Accounts.{
    AdminPassword,
    AppPasswords,
    Credentials,
    PasswordReset,
    Profile,
    Sessions
  }

  alias Atoll.Moderation.Audit
  @path "/xrpc/com.atproto.admin.updateAccountPassword"
  @did "did:web:admin-email.example.com"
  @secret "operator-password-test-secret-at-least-32"
  @password "account email test password"
  @new "replacement operator password"
  setup %{conn: conn} do
    previous =
      Map.new(
        [:admin_password, :session_signing_key, :email_worker, :email_delivery_options],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    Application.put_env(:atoll, :admin_password, @secret)
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

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

    Repo.insert!(%Profile{
      did: @did,
      handle: "admin-email.example.com",
      email: "old@example.com",
      email_confirmed_at: DateTime.utc_now()
    })

    {:ok, _} = Credentials.create(@did, @password)
    {:ok, pair} = Sessions.create(@did, @password)
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 65, div(id, 256), rem(id, 256)}}, pair: pair}
  end

  test "replaces password, revokes sessions and app passwords, and rejects stale login proofs",
       c do
    {:ok, app} = AppPasswords.create(c.pair.access_jwt, %{"name" => "old client"})
    {:ok, app_pair} = Sessions.create(@did, app.password)
    {:ok, digest} = Credentials.verified_digest(@did, @password)
    seq = Atoll.Repositories.Events.latest_seq()
    result = auth(c.conn) |> post(@path, %{did: @did, password: @new})
    assert response(result, 200) == ""
    assert get_resp_header(result, "cache-control") == ["no-store"]
    assert {:error, :invalid_credentials} = Sessions.create(@did, @password)
    assert {:error, :invalid_credentials} = Sessions.create(@did, app.password)

    assert {:error, :invalid_credentials} =
             Sessions.create_for_account(@did, credential_digest: digest)

    for pair <- [c.pair, app_pair] do
      assert {:error, :invalid_token} = Sessions.authenticate(pair.access_jwt)
      assert {:error, :invalid_token} = Sessions.refresh(pair.refresh_jwt)
    end

    assert {:ok, _} = Sessions.create(@did, @new)
    assert Atoll.Repositories.Events.latest_seq() == seq
    assert {:ok, %{entries: [entry]}} = Audit.list()
    assert entry.operation == "com.atproto.admin.updateAccountPassword"
    assert entry.requested == %{"did" => @did}
    assert entry.before == %{"sessions" => 2, "appPasswords" => 1}
    assert entry.after == %{"sessions" => 0, "appPasswords" => 0, "passwordChanged" => true}
    refute Jason.encode!(entry) =~ @new
    refute Jason.encode!(entry) =~ "$argon2"
  end

  test "invalidates real recovery codes but preserves confirmed email and email factor", c do
    parent = self()

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)
      assert message["to"] == "old@example.com"
      [_, code] = Regex.run(~r/code is: ([A-Za-z0-9_-]{32})/, message["text"])
      send(parent, {:code, code})
      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert {:ok, :requested} = PasswordReset.request(%{"email" => "old@example.com"})
    assert_receive {:code, code}

    profile =
      Repo.get!(Profile, @did) |> Ecto.Changeset.change(email_auth_factor: true) |> Repo.update!()

    assert response(auth(c.conn) |> post(@path, %{did: @did, password: @new}), 200) == ""

    assert {:error, :invalid_email_token} =
             PasswordReset.reset(%{"token" => code, "password" => @password})

    updated = Repo.get!(Profile, @did)
    assert updated.email == profile.email
    assert updated.email_confirmed_at == profile.email_confirmed_at
    assert updated.email_auth_factor
    assert is_nil(updated.password_reset_digest)
    assert is_nil(updated.password_reset_requested_at)
    assert {:ok, _} = Credentials.verify(@did, @new)
  end

  test "validation, authorization, and rollback leave credentials and history unchanged", c do
    assert c.conn
           |> put_req_header("content-type", "application/json")
           |> post(@path, "{")
           |> json_response(401)

    assert c.conn
           |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
           |> post(@path, %{did: @did, password: @new})
           |> json_response(401)

    for params <- [
          %{did: @did, password: "short"},
          %{did: @did, password: String.duplicate("x", 1025)},
          %{did: "bad", password: @new},
          %{did: @did, password: @new, extra: true},
          %{did: "did:web:unknown.example.com", password: @new}
        ] do
      assert auth(c.conn) |> post(@path, params) |> json_response(400)
    end

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, :updated} = AdminPassword.update(%{"did" => @did, "password" => @new})
               Repo.rollback(:cancelled)
             end)

    assert {:ok, _} = Credentials.verify(@did, @password)
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
    assert {:ok, %{entries: []}} = Audit.list()
  end

  test "inactive accounts stay inactive and other accounts retain their credentials", c do
    other = "did:web:other-password.example.com"
    {:ok, _} = Repositories.create(other, SigningKey.generate())
    {:ok, _} = Credentials.create(other, @password)
    {:ok, other_pair} = Sessions.create(other, @password)

    for status <- [:deactivated, :suspended, :takendown] do
      {:ok, _} = Repositories.set_status(@did, status)
      assert response(auth(c.conn) |> post(@path, %{did: @did, password: @new}), 200) == ""
      assert Repo.get!(Atoll.Repositories.Head, @did).status == status
    end

    assert {:ok, _} = Sessions.authenticate(other_pair.access_jwt)
    assert {:ok, _} = Credentials.verify(other, @password)
  end

  defp auth(conn),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Basic " <> Base.encode64("admin:" <> @secret))
end
