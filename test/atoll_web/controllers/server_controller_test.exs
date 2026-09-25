defmodule AtollWeb.ServerControllerTest do
  use AtollWeb.ConnCase, async: true

  test "describes the configured server without authentication", %{conn: conn} do
    conn = get(conn, ~p"/xrpc/com.atproto.server.describeServer")

    assert %{
             "did" => "did:web:pds.example.test",
             "availableUserDomains" => [".example.test"]
           } = json_response(conn, 200)
  end
end
