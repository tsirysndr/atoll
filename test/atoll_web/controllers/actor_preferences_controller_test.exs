defmodule AtollWeb.ActorPreferencesControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{AppPasswords, Credentials, Preference, Sessions}
  @did "did:plc:actorpreferences"
  @password "actor preferences password"
  @get "/xrpc/app.bsky.actor.getPreferences"
  @put "/xrpc/app.bsky.actor.putPreferences"
  @personal %{
    "$type" => "app.bsky.actor.defs#personalDetailsPref",
    "birthDate" => "2000-06-15T00:00:00.000Z"
  }
  @adult %{"$type" => "app.bsky.actor.defs#adultContentPref", "enabled" => true}

  setup %{conn: conn} do
    previous = Application.fetch_env(:atoll, :session_signing_key)
    Application.put_env(:atoll, :session_signing_key, :binary.copy(<<29>>, 32))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atoll, :session_signing_key, value)
        :error -> Application.delete_env(:atoll, :session_signing_key)
      end
    end)

    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    {:ok, _} = Credentials.create(@did, @password)
    {:ok, pair} = Sessions.create(@did, @password)
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 77, div(id, 256), rem(id, 256)}}, pair: pair}
  end

  defp read(c, jwt) do
    c.conn |> put_req_header("authorization", "Bearer " <> jwt) |> get(@get)
  end

  defp write(c, jwt, preferences) do
    c.conn
    |> put_req_header("authorization", "Bearer " <> jwt)
    |> put_req_header("content-type", "application/json")
    |> post(@put, Jason.encode!(%{preferences: preferences}))
  end

  test "round-trips namespaced preferences and synthesizes a declared-age preference", c do
    response = read(c, c.pair.access_jwt)
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert json_response(response, 200) == %{"preferences" => []}

    future = %{"$type" => "app.bsky.actor.defs#futurePref", "payload" => %{"nested" => [1, 2]}}

    stale_age = %{
      "$type" => "app.bsky.actor.defs#declaredAgePref",
      "isOverAge13" => false,
      "isOverAge16" => false,
      "isOverAge18" => false
    }

    assert write(c, c.pair.access_jwt, [@adult, @personal, future, stale_age])
           |> response(200) == ""

    assert %{"preferences" => preferences} = read(c, c.pair.access_jwt) |> json_response(200)

    assert preferences == [
             @adult,
             @personal,
             future,
             %{
               "$type" => "app.bsky.actor.defs#declaredAgePref",
               "isOverAge13" => true,
               "isOverAge16" => true,
               "isOverAge18" => true
             }
           ]

    assert write(c, c.pair.access_jwt, [@adult]) |> response(200) == ""
    assert read(c, c.pair.access_jwt) |> json_response(200) == %{"preferences" => [@adult]}
    assert Repo.one!(Preference).preferences == [@adult]
  end

  test "app-password sessions never read or replace personal details", c do
    assert write(c, c.pair.access_jwt, [@personal, @adult]) |> response(200) == ""
    {:ok, app} = AppPasswords.create(c.pair.access_jwt, %{"name" => "sync"})
    {:ok, restricted} = Sessions.create(@did, app.password)

    assert %{"preferences" => preferences} = read(c, restricted.access_jwt) |> json_response(200)
    types = Enum.map(preferences, & &1["$type"])
    refute "app.bsky.actor.defs#personalDetailsPref" in types
    assert "app.bsky.actor.defs#declaredAgePref" in types
    assert @adult in preferences

    assert write(c, restricted.access_jwt, [@personal]) |> json_response(400) == %{
             "error" => "InvalidRequest",
             "message" => "Invalid or unsupported query parameters."
           }

    label = %{
      "$type" => "app.bsky.actor.defs#contentLabelPref",
      "label" => "x",
      "visibility" => "hide"
    }

    assert write(c, restricted.access_jwt, [label]) |> response(200) == ""

    assert %{"preferences" => full} = read(c, c.pair.access_jwt) |> json_response(200)
    assert @personal in full
    assert label in full
    refute @adult in full
  end

  test "rejects preferences outside the app.bsky namespace and malformed envelopes", c do
    for preferences <- [
          [%{"$type" => "com.example.pref#custom"}],
          [%{"$type" => "app.bskyother.pref"}],
          [%{"missing" => "type"}],
          "not-a-list"
        ] do
      assert write(c, c.pair.access_jwt, preferences) |> json_response(400)
    end

    assert c.conn
           |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
           |> put_req_header("content-type", "application/json")
           |> post(@put, "{}")
           |> json_response(400)

    assert Repo.aggregate(Preference, :count) == 0
    assert c.conn |> get(@put) |> json_response(405)
  end

  test "requires a live session and keeps preferences available while deactivated", c do
    assert read(c, c.pair.refresh_jwt) |> json_response(401)
    assert c.conn |> get(@get) |> json_response(401)
    assert write(c, c.pair.refresh_jwt, []) |> json_response(401)

    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert write(c, c.pair.access_jwt, [@adult]) |> response(200) == ""
    assert read(c, c.pair.access_jwt) |> json_response(200) == %{"preferences" => [@adult]}
    {:ok, _} = Repositories.set_status(@did, :active)

    {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)
    assert read(c, c.pair.access_jwt) |> json_response(401)
  end

  test "takedown keeps preference exports readable without personal details or writes", c do
    assert write(c, c.pair.access_jwt, [@personal, @adult]) |> response(200) == ""
    {:ok, _} = Repositories.set_status(@did, :takendown)
    {:ok, restricted} = Sessions.create(@did, @password, allow_takendown: true)

    assert %{"preferences" => exported} = read(c, restricted.access_jwt) |> json_response(200)
    types = Enum.map(exported, & &1["$type"])
    refute "app.bsky.actor.defs#personalDetailsPref" in types
    assert @adult in exported

    assert %{"preferences" => full} = read(c, c.pair.access_jwt) |> json_response(200)
    assert @personal in full

    assert write(c, restricted.access_jwt, [@adult]) |> json_response(403)

    assert write(c, c.pair.access_jwt, [@adult]) |> json_response(400) == %{
             "error" => "RepoTakendown",
             "message" => "Repository is not active."
           }

    {:ok, _} = Repositories.set_status(@did, :active)
    assert write(c, restricted.access_jwt, [@adult]) |> json_response(403)
  end

  test "OAuth grants use transitional or RPC permissions without personal details", c do
    assert write(c, c.pair.access_jwt, [@personal]) |> response(200) == ""
    client = Atoll.OAuthFixture.grant(c.pair, "atproto transition:generic")

    assert Atoll.OAuthFixture.conn(client, @put)
           |> post(@put, Jason.encode!(%{preferences: [@adult]}))
           |> response(200) == ""

    assert %{"preferences" => preferences} =
             Atoll.OAuthFixture.conn(client, @get, "GET") |> get(@get) |> json_response(200)

    types = Enum.map(preferences, & &1["$type"])
    refute "app.bsky.actor.defs#personalDetailsPref" in types
    assert "app.bsky.actor.defs#declaredAgePref" in types
    assert @adult in preferences

    assert Atoll.OAuthFixture.conn(client, @put)
           |> post(@put, Jason.encode!(%{preferences: [@personal]}))
           |> json_response(400)

    assert %{"preferences" => full} = read(c, c.pair.access_jwt) |> json_response(200)
    assert @personal in full

    Repo.update_all(Atoll.OAuth.AccessToken, set: [scope: "atproto"])

    assert Atoll.OAuthFixture.conn(client, @put)
           |> post(@put, Jason.encode!(%{preferences: []}))
           |> json_response(403) == %{"error" => "insufficient_scope"}

    assert Atoll.OAuthFixture.conn(client, @get, "GET") |> get(@get) |> json_response(403) == %{
             "error" => "insufficient_scope"
           }

    rpc_client =
      Atoll.OAuthFixture.grant(
        c.pair,
        "atproto rpc:app.bsky.actor.getPreferences?aud=* rpc:app.bsky.actor.putPreferences?aud=*"
      )

    assert Atoll.OAuthFixture.conn(rpc_client, @put)
           |> post(@put, Jason.encode!(%{preferences: [@adult]}))
           |> response(200) == ""

    assert %{"preferences" => _} =
             Atoll.OAuthFixture.conn(rpc_client, @get, "GET") |> get(@get) |> json_response(200)
  end
end
