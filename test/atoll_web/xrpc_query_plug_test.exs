defmodule AtollWeb.XRPCQueryPlugTest do
  use AtollWeb.ConnCase, async: true

  test "ambiguous and malformed parameters return protocol errors with CORS" do
    for query <- ["limit=1&limit=2", "limit[]=1", "limit=1001", "x=%FF", "x=%GG"] do
      conn = get(build_conn(), "/xrpc/com.atproto.sync.listRepos?" <> query)
      assert %{"error" => "InvalidRequest"} = json_response(conn, 400)
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "encoded route spellings receive parameter validation" do
    conn = get(build_conn(), "/%78rpc/com.atproto.sync.%6cistRepos?limit=1001")
    assert %{"error" => "InvalidRequest"} = json_response(conn, 400)
  end

  test "valid empty queries reach the controller" do
    assert %{"repos" => []} =
             build_conn() |> get("/xrpc/com.atproto.sync.listRepos") |> json_response(200)
  end
end
