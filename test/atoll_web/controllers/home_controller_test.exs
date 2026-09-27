defmodule AtollWeb.HomeControllerTest do
  use AtollWeb.ConnCase, async: false

  setup do
    previous = Application.fetch_env!(:atoll, :pds)

    Application.put_env(
      :atoll,
      :pds,
      Keyword.put(previous, :available_user_domains, [".rocksky.social"])
    )

    on_exit(fn -> Application.put_env(:atoll, :pds, previous) end)

    did = "did:web:canary.rocksky.social"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    Atoll.Repo.insert!(%Atoll.Accounts.Profile{did: did, handle: "canary.rocksky.social"})
    %{did: did}
  end

  test "redirects the root to the full Rocksky handle", %{conn: conn} do
    for host <- ["canary.rocksky.social", "CANARY.ROCKSKY.SOCIAL"] do
      result = get(%{conn | host: host}, "/")
      assert redirected_to(result, 302) == "https://rocksky.app/profile/canary.rocksky.social"
      assert get_resp_header(result, "cache-control") == ["no-store"]
    end

    result = head(%{conn | host: "canary.rocksky.social"}, "/")
    assert redirected_to(result, 302) == "https://rocksky.app/profile/canary.rocksky.social"
    assert result.resp_body == ""
  end

  test "preserves handle resolution and API routes", %{conn: conn, did: did} do
    conn = %{conn | host: "canary.rocksky.social"}
    assert conn |> get("/.well-known/atproto-did") |> response(200) == did
    assert conn |> get("/xrpc/com.atproto.server.describeServer") |> json_response(200)
  end

  test "keeps the PDS landing page for other hosts", %{conn: conn} do
    for host <- [
          URI.parse(AtollWeb.Endpoint.url()).host,
          "rocksky.social",
          "missing.rocksky.social",
          "canary.rocksky.social.attacker.example",
          "nested.canary.rocksky.social"
        ] do
      assert get(%{conn | host: host}, "/") |> response(200) =~ "Personal Data Server"
    end
  end
end
