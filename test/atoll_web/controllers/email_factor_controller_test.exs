defmodule AtollWeb.EmailFactorControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.Accounts.{AppPasswords, Credentials, EmailUpdate, Profile, Session, Sessions}
  alias Atoll.{Repo, Repositories, SigningKey}
  @did "did:web:factor.example.com"
  @password "email factor account password"
  @prefix "/xrpc/com.atproto.server."

  setup %{conn: conn} do
    previous =
      Map.new(
        [:session_signing_key, :email_worker, :email_delivery_options, :session_max_count],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    Application.put_env(:atoll, :session_signing_key, :binary.copy(<<35>>, 32))

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
      handle: "factor.example.com",
      email: "owner@example.com",
      email_confirmed_at: DateTime.utc_now()
    })

    {:ok, _} = Credentials.create(@did, @password)
    {:ok, pair} = Sessions.create(@did, @password)
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 49, div(id, 256), rem(id, 256)}}, pair: pair}
  end

  test "enables through current-email authorization and requires a one-use login factor", c do
    toggle(c, true)
    assert Repo.get!(Profile, @did).email_auth_factor
    code = challenge(c)
    assert Repo.aggregate(Session, :count) == 1
    assert byte_size(Repo.get!(Profile, @did).auth_factor_digest) == 32
    assert json_response(login(c), 400)["error"] == "AuthFactorTokenRequired"
    assert response(login(c, %{authFactorToken: String.duplicate("x", 32)}), 401)

    result =
      login(c, %{identifier: "OWNER@example.com", authFactorToken: code}) |> json_response(200)

    assert result["emailAuthFactor"] == true
    assert Repo.aggregate(Session, :count) == 2
    assert is_nil(Repo.get!(Profile, @did).auth_factor_digest)
    assert response(login(c, %{authFactorToken: code}), 401)
    assert {:ok, _} = Sessions.authenticate(result["accessJwt"])
  end

  test "wrong passwords do not send a factor and app-password logins remain restricted", c do
    {:ok, app} = AppPasswords.create(c.pair.access_jwt, %{"name" => "trusted client"})
    toggle(c, true)
    assert response(login(c, %{password: "incorrect password"}), 401)
    assert is_nil(Repo.get!(Profile, @did).auth_factor_digest)
    pair = login(c, %{password: app.password}) |> json_response(200)
    assert {:error, :forbidden} = Sessions.authenticate_management(pair["accessJwt"])
    assert is_nil(Repo.get!(Profile, @did).auth_factor_digest)
  end

  test "expiry and replacement reject old codes, and failed session creation preserves the valid code",
       c do
    toggle(c, true)
    old = challenge(c)
    change(auth_factor_expires_at: System.system_time(:second) - 1)
    assert response(login(c, %{authFactorToken: old}), 401)
    change(auth_factor_requested_at: System.system_time(:second) - 61)
    code = challenge(c)
    assert response(login(c, %{authFactorToken: old}), 401)
    Application.put_env(:atoll, :session_max_count, 1)
    assert response(login(c, %{authFactorToken: code}), 429)
    refute is_nil(Repo.get!(Profile, @did).auth_factor_digest)
    Application.put_env(:atoll, :session_max_count, 100)
    assert json_response(login(c, %{authFactorToken: code}), 200)["did"] == @did
  end

  test "factor cannot be enabled for a changed or unconfirmed address", c do
    change(email_confirmed_at: nil)

    assert {:error, :email_factor_unconfirmed} =
             EmailUpdate.update(
               c.pair.access_jwt,
               %{"email" => "owner@example.com", "emailAuthFactor" => true}
             )

    assert {:ok, :unchanged} =
             EmailUpdate.update(c.pair.access_jwt, %{
               "email" => "owner@example.com",
               "emailAuthFactor" => false
             })

    change(email_confirmed_at: DateTime.utc_now())
    code = update_code(c)

    assert {:error, :email_factor_unconfirmed} =
             EmailUpdate.update(
               c.pair.access_jwt,
               %{"email" => "changed@example.com", "emailAuthFactor" => true, "token" => code}
             )

    assert {:ok, :updated} =
             EmailUpdate.update(
               c.pair.access_jwt,
               %{"email" => "changed@example.com", "token" => code}
             )

    assert Repo.get!(Profile, @did).email_auth_factor == false
  end

  test "disabling clears outstanding codes and enabling cannot race past a verified password",
       c do
    {:ok, digest} = Credentials.verified_digest(@did, @password)
    toggle(c, true)

    assert {:error, :auth_factor_required} =
             Sessions.create_for_account(@did, credential_digest: digest)

    code = challenge(c)
    change(email_update_requested_at: System.system_time(:second) - 61)
    toggle(c, false)
    assert is_nil(Repo.get!(Profile, @did).auth_factor_digest)
    assert response(login(c, %{authFactorToken: code}), 400)
    assert response(login(c), 200)
  end

  test "Worker failure and unavailable account never issue a session", c do
    toggle(c, true)
    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 503, "private provider failure"))
    assert json_response(login(c), 503)["error"] == "ServiceUnavailable"
    assert Repo.aggregate(Session, :count) == 1
    {:ok, _} = Repositories.set_status(@did, :suspended)
    assert response(login(c), 400)
    assert Repo.aggregate(Session, :count) == 1
  end

  test "password recovery clears challenges but keeps the enabled factor", c do
    toggle(c, true)
    old = challenge(c)
    expect_code()

    assert {:ok, :requested} =
             Atoll.Accounts.PasswordReset.request(%{"email" => "owner@example.com"})

    assert_receive {:code, reset_code}

    assert {:ok, :reset} =
             Atoll.Accounts.PasswordReset.reset(%{
               "token" => reset_code,
               "password" => "replacement account password"
             })

    profile = Repo.get!(Profile, @did)
    assert profile.email_auth_factor
    assert is_nil(profile.auth_factor_digest)

    assert response(
             login(c, %{password: "replacement account password", authFactorToken: old}),
             401
           )

    change(auth_factor_requested_at: System.system_time(:second) - 61)
    expect_code()

    assert json_response(login(c, %{password: "replacement account password"}), 400)["error"] ==
             "AuthFactorTokenRequired"

    assert_receive {:code, new}

    assert response(
             login(c, %{password: "replacement account password", authFactorToken: new}),
             200
           )
  end

  test "taken-down login still requires and consumes the Cloudflare Worker email factor", c do
    toggle(c, true)
    {:ok, _} = Repositories.set_status(@did, :takendown)
    expect_code()

    assert login(c, %{allowTakendown: true}) |> json_response(400) ==
             %{
               "error" => "AuthFactorTokenRequired",
               "message" => "Check your email for a login code."
             }

    assert_receive {:code, code}
    response = login(c, %{allowTakendown: true, authFactorToken: code}) |> json_response(200)

    assert {:ok, %{"scope" => "com.atproto.takendown"}} =
             Atoll.Accounts.Tokens.verify(response["accessJwt"], :access)

    assert login(c, %{allowTakendown: true, authFactorToken: code}) |> json_response(401)
  end

  defp toggle(c, enabled) do
    code = update_code(c)

    result =
      c.conn
      |> auth(c.pair.access_jwt)
      |> json_post(
        @prefix <> "updateEmail",
        %{email: "owner@example.com", token: code, emailAuthFactor: enabled}
      )

    assert response(result, 200) == ""
  end

  defp update_code(c) do
    expect_code()

    assert c.conn
           |> auth(c.pair.access_jwt)
           |> post(@prefix <> "requestEmailUpdate")
           |> json_response(200) == %{"tokenRequired" => true}

    assert_receive {:code, code}
    code
  end

  defp challenge(c) do
    expect_code()
    assert json_response(login(c), 400)["error"] == "AuthFactorTokenRequired"
    assert_receive {:code, code}
    code
  end

  defp expect_code do
    parent = self()

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)
      assert message["to"] == "owner@example.com"
      [_, code] = Regex.run(~r/code is: ([A-Za-z0-9_-]{32})/, message["text"])
      send(parent, {:code, code})
      Plug.Conn.send_resp(conn, 202, "")
    end)
  end

  defp change(attrs),
    do: Repo.get!(Profile, @did) |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp login(c, attrs \\ %{}),
    do:
      json_post(
        c.conn,
        @prefix <> "createSession",
        Map.merge(%{identifier: @did, password: @password}, attrs)
      )

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp json_post(conn, path, params),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(params))
end
