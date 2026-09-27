defmodule AtollWeb.ReadOnlyTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Repositories, SigningKey}
  alias Atoll.Accounts.{Credentials, Sessions}
  @did "did:web:readonly.example.com"

  setup %{conn: conn} do
    previous = Application.fetch_env(:atoll, :session_signing_key)
    Application.put_env(:atoll, :session_signing_key, :binary.copy(<<37>>, 32))
    Application.put_env(:atoll, :read_only, true)

    on_exit(fn ->
      Application.delete_env(:atoll, :read_only)

      case previous do
        {:ok, value} -> Application.put_env(:atoll, :session_signing_key, value)
        :error -> Application.delete_env(:atoll, :session_signing_key)
      end
    end)

    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    {:ok, _} = Credentials.create(@did, "read only password")
    {:ok, pair} = Sessions.create(@did, "read only password")
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 55, div(id, 256), rem(id, 256)}}, pair: pair}
  end

  test "refuses every mutation before parsing while keeping reads available", c do
    refusal = %{
      "error" => "ServiceUnavailable",
      "message" => "The server is in read-only maintenance mode."
    }

    for path <- [
          "/xrpc/com.atproto.server.createSession",
          "/xrpc/com.atproto.repo.createRecord",
          "/xrpc/app.bsky.actor.putPreferences",
          "/oauth/par"
        ] do
      response = c.conn |> put_req_header("content-type", "application/json") |> post(path, "{}")
      assert json_response(response, 503) == refusal
      assert get_resp_header(response, "retry-after") == ["30"]
      assert get_resp_header(response, "cache-control") == ["no-store"]
    end

    # OAuth-credentialed reads persist proof state, so they are refused too.
    assert c.conn
           |> put_req_header("authorization", "DPoP atoll_access_" <> String.duplicate("a", 43))
           |> put_req_header("dpop", "proof")
           |> get("/xrpc/com.atproto.server.getSession")
           |> json_response(503) == refusal

    assert json_response(get(c.conn, "/xrpc/com.atproto.server.describeServer"), 200)
    assert response(get(c.conn, "/health"), 200)

    assert c.conn
           |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
           |> get("/xrpc/app.bsky.actor.getPreferences")
           |> json_response(200) == %{"preferences" => []}
  end

  test "preflights pass and workers are neither expected nor started", c do
    response =
      c.conn
      |> put_req_header("origin", "https://app.example.com")
      |> put_req_header("access-control-request-method", "POST")
      |> put_req_header("access-control-request-headers", "authorization")
      |> options("/xrpc/com.atproto.repo.createRecord")

    assert response.status == 204

    Application.put_env(:atoll, :relay_crawl_enabled, true)
    on_exit(fn -> Application.delete_env(:atoll, :relay_crawl_enabled) end)

    for row <- Atoll.WorkerProgress.inventory() do
      assert row.expected == 0
      assert row.present == 0
    end

    assert AtollWeb.ReadOnlyPlug.enabled_from_env!(nil) == false
    assert AtollWeb.ReadOnlyPlug.enabled_from_env!("true") == true

    assert_raise ArgumentError, fn -> AtollWeb.ReadOnlyPlug.enabled_from_env!("yes") end
  end
end
