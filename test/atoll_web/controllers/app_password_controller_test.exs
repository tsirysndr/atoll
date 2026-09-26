defmodule AtollWeb.AppPasswordControllerTest do
  use AtollWeb.ConnCase, async: false

  alias Atoll.Accounts.{
    AppPassword,
    AppPasswords,
    Credentials,
    Profile,
    Session,
    Sessions,
    Tokens
  }

  alias Atoll.{KeyVault, Repo, Repositories, SigningKey}
  @did "did:web:app-password.example.com"
  @password "full account password"
  @prefix "/xrpc/com.atproto.server."

  setup %{conn: conn} do
    previous =
      Map.new(
        [:session_signing_key, :key_encryption_key],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    for key <- Map.keys(previous), do: Application.put_env(:atoll, key, :binary.copy(<<34>>, 32))

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
    {:ok, _} = KeyVault.store(@did, key)

    Repo.insert!(%Profile{
      did: @did,
      handle: "app-password.example.com",
      email: "owner@example.com"
    })

    {:ok, _} = Credentials.create(@did, @password)
    {:ok, pair} = Sessions.create(@did, @password)
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 48, div(id, 256), rem(id, 256)}}, pair: pair}
  end

  test "creates once, lists metadata only, supports email login and revokes every app session",
       c do
    app = create(c, %{name: "phone"}) |> json_response(200)
    assert app["name"] == "phone"
    assert app["privileged"] == false
    assert byte_size(app["password"]) == 39
    stored = Repo.one!(AppPassword)
    refute inspect(stored) =~ app["password"]
    assert byte_size(stored.digest) == 32

    listed =
      c.conn
      |> auth(c.pair.access_jwt)
      |> get(@prefix <> "listAppPasswords")
      |> json_response(200)

    assert listed == %{"passwords" => [Map.delete(app, "password")]}
    first = login(c, app["password"], "OWNER@example.com") |> json_response(200)
    second = login(c, app["password"]) |> json_response(200)
    assert {:ok, claims} = Tokens.verify(first["accessJwt"], :access)
    assert claims["scope"] == "com.atproto.appPass"
    assert {:ok, _} = Sessions.authenticate(first["accessJwt"])
    assert response(revoke(c, "phone"), 200) == ""
    assert response(revoke(c, "phone"), 200) == ""

    for pair <- [first, second] do
      assert {:error, :invalid_token} = Sessions.authenticate(pair["accessJwt"])
      assert {:error, :invalid_token} = Sessions.refresh(pair["refreshJwt"])
    end

    assert response(login(c, app["password"]), 401)
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
    assert Repo.aggregate(Session, :count) == 1
    # Revocation also rejects a credential proof obtained before the delete.
    assert {:error, :invalid_credentials} =
             Sessions.create_for_account(@did,
               app_password_id: stored.id,
               access_scope: "com.atproto.appPass"
             )
  end

  test "restricted sessions refresh without escalation and cannot manage accounts", c do
    app = create(c, %{name: "writer"}) |> json_response(200)
    pair = login(c, app["password"]) |> json_response(200)
    access = pair["accessJwt"]
    assert response(c.conn |> auth(access) |> get(@prefix <> "getSession"), 200)

    for {method, path, body} <- [
          {:post, "createAppPassword", %{name: "forbidden"}},
          {:get, "listAppPasswords", nil},
          {:post, "revokeAppPassword", %{name: "writer"}},
          {:post, "requestEmailConfirmation", nil},
          {:post, "requestEmailUpdate", nil},
          {:post, "updateEmail", %{email: "attacker@example.com"}},
          {:post, "deactivateAccount", %{}},
          {:get, "checkAccountStatus", nil}
        ] do
      conn = c.conn |> auth(access)
      conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

      result =
        dispatch(
          conn,
          @endpoint,
          method,
          @prefix <> path,
          if(body, do: Jason.encode!(body), else: nil)
        )

      assert result.status == 403, "#{path}: #{result.resp_body}"
    end

    refreshed =
      c.conn
      |> auth(pair["refreshJwt"])
      |> post(@prefix <> "refreshSession")
      |> json_response(200)

    assert {:ok, %{"scope" => "com.atproto.appPass", "sid" => sid}} =
             Tokens.verify(refreshed["accessJwt"], :access)

    {:ok, forged} = Tokens.pair(@did, sid)
    assert {:error, :invalid_token} = Sessions.authenticate(forged.access_jwt)
    assert {:error, :invalid_token} = Sessions.authenticate_management(forged.access_jwt)
  end

  test "app sessions can upload blobs and write records", c do
    app = create(c, %{name: "writer"}) |> json_response(200)
    pair = login(c, app["password"]) |> json_response(200)
    token = pair["accessJwt"]

    upload =
      c.conn
      |> auth(token)
      |> put_req_header("content-type", "text/plain")
      |> post("/xrpc/com.atproto.repo.uploadBlob", "app blob")
      |> json_response(200)

    assert upload["blob"]["size"] == 8
    record = %{"$type" => "com.example.note", "text" => "app write"}

    written =
      c.conn
      |> auth(token)
      |> json_post("/xrpc/com.atproto.repo.createRecord", %{
        repo: @did,
        collection: "com.example.note",
        record: record
      })

    assert json_response(written, 200)["uri"] =~ @did
  end

  test "service tokens require a method and reserve chat methods for privileged app passwords",
       c do
    for privileged <- [false, true] do
      app =
        create(c, %{name: "service-#{privileged}", privileged: privileged}) |> json_response(200)

      pair = login(c, app["password"]) |> json_response(200)
      {:ok, claims} = Tokens.verify(pair["accessJwt"], :access)

      assert claims["scope"] ==
               if(privileged, do: "com.atproto.appPassPrivileged", else: "com.atproto.appPass")

      service = fn params ->
        c.conn
        |> auth(pair["accessJwt"])
        |> get(@prefix <> "getServiceAuth", Map.put(params, :aud, "did:web:service.example.com"))
      end

      assert response(service.(%{}), 403)
      assert response(service.(%{lxm: "com.atproto.server.createAccount"}), 403)

      assert response(
               service.(%{lxm: "chat.bsky.convo.listConvos"}),
               if(privileged, do: 200, else: 403)
             )

      assert response(service.(%{lxm: "app.bsky.feed.getTimeline"}), 200)
      assert {:error, :forbidden} = Sessions.authenticate_management(pair["accessJwt"])

      refreshed =
        c.conn
        |> auth(pair["refreshJwt"])
        |> post(@prefix <> "refreshSession")
        |> json_response(200)

      assert {:ok, next} = Tokens.verify(refreshed["accessJwt"], :access)
      assert next["scope"] == claims["scope"]
    end
  end

  test "invalid names, duplicates and account cap fail without overwriting credentials", c do
    for params <- [
          %{},
          %{name: ""},
          %{name: "\n"},
          %{name: String.duplicate("x", 129)},
          %{name: "app", privileged: "true"}
        ] do
      assert response(create(c, params), 400)
    end

    first = create(c, %{name: "unique"}) |> json_response(200)
    assert response(create(c, %{name: "unique"}), 400)
    assert response(login(c, first["password"]), 200)

    for n <- 1..99,
        do:
          Repo.insert!(%AppPassword{
            did: @did,
            name: "fixture-#{n}",
            digest: :crypto.hash(:sha256, "#{n}")
          })

    assert {:error, :app_password_limit} =
             AppPasswords.create(c.pair.access_jwt, %{"name" => "over-limit"})

    assert response(c.conn |> get(@prefix <> "listAppPasswords"), 401)
    assert response(c.conn |> auth(c.pair.access_jwt) |> get(@prefix <> "createAppPassword"), 405)
  end

  defp create(c, params),
    do: c.conn |> auth(c.pair.access_jwt) |> json_post(@prefix <> "createAppPassword", params)

  defp revoke(c, name),
    do:
      c.conn
      |> auth(c.pair.access_jwt)
      |> json_post(@prefix <> "revokeAppPassword", %{name: name})

  defp login(c, password, identifier \\ @did),
    do:
      json_post(c.conn, @prefix <> "createSession", %{identifier: identifier, password: password})

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp json_post(conn, path, params),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(params))
end
