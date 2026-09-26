defmodule AtollWeb.TakendownSessionControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Blobs, KeyVault, Repositories, SigningKey}
  alias Atoll.Accounts.{AppPasswords, Credentials, Sessions, Tokens}
  @did "did:web:restricted-session.example.com"
  @password "restricted account password"
  @prefix "/xrpc/com.atproto.server."

  setup %{conn: conn} do
    prior =
      Map.new(
        [:session_signing_key, :key_encryption_key],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    for key <- Map.keys(prior),
        do: Application.put_env(:atoll, key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, :stored} = KeyVault.store(@did, key)
    {:ok, _} = Credentials.create(@did, @password)
    {:ok, full} = Sessions.create(@did, @password)
    {:ok, blob} = Blobs.stage(@did, "owner-export-bytes", "text/plain")

    {:ok, _} =
      Repositories.apply_writes(
        @did,
        [{:put, "com.example.record/one", %{"$type" => "com.example.record", "blob" => blob}}],
        key
      )

    {:ok, car} = Repositories.export(@did)
    id = rem(System.unique_integer([:positive]), 65_536)

    %{
      conn: %{conn | remote_ip: {10, 63, div(id, 256), rem(id, 256)}},
      full: full,
      blob: blob,
      car: car
    }
  end

  test "opt-in login issues restricted tokens for owner exports without opening public sync", c do
    {:ok, _} = Repositories.set_status(@did, :takendown)
    assert login(c, %{allowTakendown: false}) |> json_response(400)
    result = login(c) |> json_response(200)
    assert result["status"] == "takendown"
    assert result["active"] == false

    assert {:ok, %{"scope" => "com.atproto.takendown"}} =
             Tokens.verify(result["accessJwt"], :access)

    token = result["accessJwt"]
    cid = c.blob["ref"]["$link"]

    for {method, params} <- [
          {"getRepo", %{did: @did}},
          {"listBlobs", %{did: @did}},
          {"getBlob", %{did: @did, cid: cid}}
        ] do
      assert get(c.conn, "/xrpc/com.atproto.sync." <> method, params) |> json_response(400)
    end

    archive = export(c, token, "getRepo", %{did: @did})
    assert Atoll.CAR.decode(response(archive, 200)) == Atoll.CAR.decode(c.car)
    assert get_resp_header(archive, "cache-control") == ["no-store"]
    assert export(c, token, "listBlobs", %{did: @did}) |> json_response(200) == %{"cids" => [cid]}

    assert export(c, token, "getBlob", %{did: @did, cid: cid}) |> response(200) ==
             "owner-export-bytes"

    assert Atoll.CAR.decode(
             export(c, c.full.access_jwt, "getRepo", %{did: @did})
             |> response(200)
           ) == Atoll.CAR.decode(c.car)

    # Blob-specific restrictions still apply to the owner.
    {:ok, _} =
      Atoll.Accounts.SubjectStatus.update(%{
        "subject" => %{
          "$type" => "com.atproto.admin.defs#repoBlobRef",
          "did" => @did,
          "cid" => cid
        },
        "takedown" => %{"applied" => true}
      })

    assert export(c, token, "getBlob", %{did: @did, cid: cid}) |> json_response(400)
    assert export(c, token, "listBlobs", %{did: @did}) |> json_response(200) == %{"cids" => []}
  end

  test "restricted access never becomes ordinary authority, even after restoration", c do
    {:ok, _} = Repositories.set_status(@did, :takendown)
    pair = login(c) |> json_response(200)
    token = pair["accessJwt"]

    assert auth(c.conn, pair["refreshJwt"])
           |> post(@prefix <> "refreshSession")
           |> json_response(400)

    for state <- [:takendown, :active] do
      {:ok, _} = Repositories.set_status(@did, state)
      assert {:error, :forbidden} = Sessions.authenticate(token)
      assert {:error, :forbidden} = Sessions.authenticate_management(token)
      assert {:error, :forbidden} = Sessions.authenticate_session(token)
      assert {:error, :forbidden} = Sessions.authenticate_status(token)
      assert auth(c.conn, token) |> get(@prefix <> "getSession") |> json_response(403)

      assert auth(c.conn, token)
             |> json_post("/xrpc/com.atproto.repo.putRecord", %{
               repo: @did,
               collection: "com.example.record",
               rkey: "two",
               record: %{"$type" => "com.example.record"}
             })
             |> json_response(403)

      assert auth(c.conn, token)
             |> json_post(@prefix <> "deactivateAccount", %{})
             |> json_response(403)

      assert auth(c.conn, token)
             |> json_post(@prefix <> "createAppPassword", %{name: "forbidden"})
             |> json_response(403)
    end

    refreshed =
      auth(c.conn, pair["refreshJwt"]) |> post(@prefix <> "refreshSession") |> json_response(200)

    assert {:ok, %{"scope" => "com.atproto.access"}} =
             Tokens.verify(refreshed["accessJwt"], :access)

    assert {:ok, _} = Sessions.authenticate(refreshed["accessJwt"])
    assert {:error, :forbidden} = Sessions.authenticate(token)
    assert {:ok, :ok} = Sessions.revoke(refreshed["refreshJwt"])
    assert export(c, token, "getRepo", %{did: @did}) |> json_response(401)
  end

  test "app-password origin survives restricted login and restoration without privilege upgrades",
       c do
    for privileged <- [false, true] do
      {:ok, app} =
        AppPasswords.create(c.full.access_jwt, %{
          "name" => "app-#{privileged}",
          "privileged" => privileged
        })

      {:ok, _} = Repositories.set_status(@did, :takendown)
      pair = login(c, %{password: app.password}) |> json_response(200)

      assert {:ok, %{"scope" => "com.atproto.takendown"}} =
               Tokens.verify(pair["accessJwt"], :access)

      assert Atoll.CAR.decode(
               export(c, pair["accessJwt"], "getRepo", %{did: @did})
               |> response(200)
             ) == Atoll.CAR.decode(c.car)

      {:ok, _} = Repositories.set_status(@did, :active)

      refreshed =
        auth(c.conn, pair["refreshJwt"])
        |> post(@prefix <> "refreshSession")
        |> json_response(200)

      expected = if privileged, do: "com.atproto.appPassPrivileged", else: "com.atproto.appPass"
      assert {:ok, %{"scope" => ^expected}} = Tokens.verify(refreshed["accessJwt"], :access)
      assert {:error, :forbidden} = Sessions.authenticate_management(refreshed["accessJwt"])
      assert {:ok, _} = AppPasswords.revoke(c.full.access_jwt, %{"name" => "app-#{privileged}"})
      assert export(c, pair["accessJwt"], "getRepo", %{did: @did}) |> json_response(401)
    end
  end

  test "exports reject cross-account, malformed, refresh, expired and revoked tokens", c do
    other = "did:web:other-export.example.com"
    {:ok, _} = Repositories.create(other, SigningKey.generate())
    {:ok, _} = Repositories.set_status(@did, :takendown)
    pair = login(c) |> json_response(200)
    assert {:error, :invalid_token} = Repositories.export(@did, nil, false)
    assert export(c, pair["accessJwt"], "getRepo", %{did: other}) |> response(200)
    {:ok, _} = Repositories.set_status(other, :takendown)
    assert export(c, pair["accessJwt"], "getRepo", %{did: other}) |> json_response(400)

    for token <- ["invalid", pair["refreshJwt"]] do
      assert export(c, token, "getRepo", %{did: @did}) |> json_response(401)
    end

    now = System.system_time(:second)
    assert {:ok, old} = Sessions.create(@did, @password, allow_takendown: true, now: now - 7201)
    assert export(c, old.access_jwt, "getRepo", %{did: @did}) |> json_response(401)

    assert auth(c.conn, pair["refreshJwt"]) |> post(@prefix <> "deleteSession") |> response(200) ==
             ""

    assert export(c, pair["accessJwt"], "getRepo", %{did: @did}) |> json_response(401)
    assert export(c, pair["accessJwt"], "listBlobs", %{did: @did}) |> json_response(401)
  end

  test "deactivated exports require owner credentials and suspension never allows opt-in login",
       c do
    {:ok, _} = Repositories.set_status(@did, :deactivated)

    assert Atoll.CAR.decode(
             export(c, c.full.access_jwt, "getRepo", %{did: @did})
             |> response(200)
           ) == Atoll.CAR.decode(c.car)

    assert get(c.conn, "/xrpc/com.atproto.sync.getRepo", %{did: @did}) |> json_response(400)
    {:ok, _} = Repositories.set_status(@did, :suspended)
    assert login(c) |> json_response(400)
    assert export(c, c.full.access_jwt, "getRepo", %{did: @did}) |> json_response(400)
    {:ok, _} = Repositories.set_status(@did, :takendown)
    assert login(c) |> json_response(400)
    assert export(c, c.full.access_jwt, "getRepo", %{did: @did}) |> json_response(400)
  end

  defp login(c, attrs \\ %{}),
    do:
      json_post(
        c.conn,
        @prefix <> "createSession",
        Map.merge(%{identifier: @did, password: @password, allowTakendown: true}, attrs)
      )

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp json_post(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp export(c, token, method, params),
    do: auth(c.conn, token) |> get("/xrpc/com.atproto.sync." <> method, params)
end
