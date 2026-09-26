defmodule AtollWeb.XRPCRequestPlugTest do
  use AtollWeb.ConnCase, async: true

  test "every implemented route rejects other HTTP methods before parsing" do
    routes = Enum.filter(AtollWeb.Router.__routes__(), &String.starts_with?(&1.path, "/xrpc/"))

    for route <- routes,
        method <- [:get, :post, :put, :patch, :delete, :head, :options],
        method != route.verb do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> dispatch(@endpoint, method, route.path, "{invalid json")

      if method == :head do
        assert response(conn, 405) == ""
      else
        assert %{"error" => "MethodNotAllowed"} = json_response(conn, 405)
      end

      assert get_resp_header(conn, "allow") == [route.verb |> Atom.to_string() |> String.upcase()]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "unknown methods return an XRPC error before body parsing" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/xrpc/com.example.unknown", "{invalid json")

    assert %{"error" => "MethodNotImplemented"} = json_response(conn, 501)
  end

  test "malformed XRPC paths return protocol errors" do
    for path <- [
          "/xrpc",
          "/xrpc/",
          "/xrpc/bad",
          "/xrpc/com.example.foo/extra",
          "/xrpc/com.example.%2Ffoo",
          "/xrpc/com.example.%FF"
        ] do
      conn = get(build_conn(), path)
      assert %{"error" => "InvalidRequest"} = json_response(conn, 400)
    end
  end

  test "encoded route spellings have the same method checks and behavior" do
    path = "/%78rpc/com.atproto.server.%64escribeServer"
    assert %{"did" => _} = build_conn() |> get(path) |> json_response(200)
    assert %{"error" => "MethodNotAllowed"} = build_conn() |> post(path) |> json_response(405)

    path = "/%78rpc/com.atproto.sync.%73ubscribeRepos"
    assert %{"error" => "UpgradeRequired"} = build_conn() |> get(path) |> json_response(426)
    assert %{"error" => "MethodNotAllowed"} = build_conn() |> post(path) |> json_response(405)
  end

  test "non-XRPC routes remain available" do
    assert %{"status" => "ok"} = build_conn() |> get("/health") |> json_response(200)
    assert build_conn() |> get("/") |> response(200) =~ "Personal Data Server"
  end
end
