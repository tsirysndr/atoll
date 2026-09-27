defmodule AtollWeb.XRPCCORSTest do
  use AtollWeb.ConnCase, async: true

  test "all routed XRPC endpoints support unauthenticated preflight" do
    routes = Enum.filter(AtollWeb.Router.__routes__(), &String.starts_with?(&1.path, "/xrpc/"))

    for route <- routes do
      method = route.verb |> Atom.to_string() |> String.upcase()
      conn = preflight(route.path, method, "Authorization, Content-Type, Atproto-Proxy")
      assert response(conn, 204) == ""
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      assert get_resp_header(conn, "access-control-allow-methods") == [method]
      assert get_resp_header(conn, "access-control-allow-credentials") == []
      assert get_resp_header(conn, "access-control-max-age") == ["600"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "preflight does not grant authentication for the actual request" do
    path = "/xrpc/com.atproto.server.getSession"
    assert preflight(path, "GET", "authorization").status == 204
    conn = build_conn() |> put_req_header("origin", "https://client.example") |> get(path)
    assert %{"error" => "AuthRequired"} = json_response(conn, 401)
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    assert get_resp_header(conn, "access-control-expose-headers") |> hd() =~ "www-authenticate"
  end

  test "public responses and routing errors expose CORS headers" do
    for {path, status} <- [
          {"/xrpc/com.atproto.server.describeServer", 200},
          {"/xrpc/com.example.unknown", 501},
          {"/xrpc/bad", 400}
        ] do
      conn = get(build_conn(), path)
      assert conn.status == status
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end

    assert get_resp_header(get(build_conn(), "/health"), "access-control-allow-origin") == []
  end

  test "preflights reflect arbitrary well-formed requested headers" do
    path = "/xrpc/com.atproto.server.describeServer"

    # The reference client sends headers beyond a fixed allowlist; reflect them.
    conn = preflight(path, "GET", "authorization, atproto-proxy, dpop, x-unrecognized")
    assert response(conn, 204) == ""

    assert get_resp_header(conn, "access-control-allow-headers") == [
             "authorization, atproto-proxy, dpop, x-unrecognized"
           ]

    # No requested headers advertises the default set.
    conn = preflight(path, "GET", nil)
    assert response(conn, 204) == ""
    assert get_resp_header(conn, "access-control-allow-headers") |> hd() =~ "authorization"
  end

  test "preflights reject method mismatches and malformed header values" do
    path = "/xrpc/com.atproto.server.describeServer"

    for {method, headers} <- [
          {"POST", "authorization"},
          {"get", "authorization"},
          {"GET", "bad header"},
          {"GET", "authorization\tdpop"},
          {"GET", String.duplicate("a", 4097)}
        ] do
      conn = preflight(path, method, headers)
      assert %{"error" => "InvalidRequest"} = json_response(conn, 400)
      assert get_resp_header(conn, "access-control-allow-methods") == []
    end

    conn = build_conn()

    conn = %{
      conn
      | req_headers: [
          {"origin", "https://one.example"},
          {"origin", "https://two.example"},
          {"access-control-request-method", "GET"}
        ]
    }

    assert conn |> options(path) |> json_response(400) == %{
             "error" => "InvalidRequest",
             "message" => "Invalid CORS preflight."
           }
  end

  test "OPTIONS without preflight headers remains a method error" do
    assert %{"error" => "MethodNotAllowed"} =
             build_conn()
             |> options("/xrpc/com.atproto.server.describeServer")
             |> json_response(405)
  end

  test "subscriptions and encoded paths support preflight without upgrading" do
    conn = preflight("/%78rpc/com.atproto.sync.%73ubscribeRepos", "GET", "accept")
    assert response(conn, 204) == ""
    assert get_resp_header(conn, "upgrade") == []
  end

  defp preflight(path, method, headers) do
    conn =
      build_conn()
      |> put_req_header("origin", "https://client.example")
      |> put_req_header("access-control-request-method", method)

    conn =
      if headers, do: put_req_header(conn, "access-control-request-headers", headers), else: conn

    options(conn, path)
  end
end
