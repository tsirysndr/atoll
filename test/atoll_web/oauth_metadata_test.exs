defmodule AtollWeb.OAuthMetadataTest do
  use AtollWeb.ConnCase, async: false
  @origin "https://pds.example.com"
  @as "/.well-known/oauth-authorization-server"
  @rs "/.well-known/oauth-protected-resource"

  setup do
    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)
    localhost = Application.fetch_env(:atoll, :localhost_dids_enabled)
    configure(scheme: "https", host: "pds.example.com", port: 443)

    on_exit(fn ->
      AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], [])

      case localhost do
        {:ok, value} -> Application.put_env(:atoll, :localhost_dids_enabled, value)
        :error -> Application.delete_env(:atoll, :localhost_dids_enabled)
      end
    end)

    :ok
  end

  test "resource discovery leads to consistent implemented authorization capabilities", %{
    conn: conn
  } do
    result = get(conn, @origin <> @rs)
    resource = json_response(result, 200)
    assert resource["resource"] == @origin
    assert resource["authorization_servers"] == [@origin]
    assert resource["dpop_signing_alg_values_supported"] == ["ES256"]
    refute Map.has_key?(resource, "dpop_bound_access_tokens_required")
    authorization = get(conn, hd(resource["authorization_servers"]) <> @as) |> json_response(200)
    assert authorization["issuer"] == @origin
    assert authorization["protected_resources"] == [@origin]
    assert authorization["authorization_endpoint"] == @origin <> "/oauth/authorize"
    assert authorization["pushed_authorization_request_endpoint"] == @origin <> "/oauth/par"
    assert authorization["token_endpoint"] == @origin <> "/oauth/token"
    assert authorization["grant_types_supported"] == ["authorization_code", "refresh_token"]
    assert authorization["response_types_supported"] == ["code"]
    assert authorization["response_modes_supported"] == ["query"]
    assert authorization["code_challenge_methods_supported"] == ["S256"]
    assert authorization["token_endpoint_auth_methods_supported"] == ["none", "private_key_jwt"]
    assert authorization["token_endpoint_auth_signing_alg_values_supported"] == ["ES256"]
    assert authorization["dpop_signing_alg_values_supported"] == ["ES256"]

    assert authorization["scopes_supported"] ==
             ~w(atproto transition:generic transition:chat.bsky transition:email repo:* blob:*/* account:email account:email?action=manage account:repo account:repo?action=manage identity:handle identity:*)

    assert authorization["scopes_supported"] == resource["scopes_supported"]
    assert authorization["prompt_values_supported"] == ["create"]
    assert authorization["authorization_response_iss_parameter_supported"]
    assert authorization["require_pushed_authorization_requests"]
    assert authorization["require_request_uri_registration"]
    assert authorization["client_id_metadata_document_supported"]

    for field <-
          ~w(jwks_uri registration_endpoint revocation_endpoint introspection_endpoint userinfo_endpoint),
        do: refute(Map.has_key?(authorization, field))
  end

  test "documents are public, cacheable and usable from browser clients", %{conn: conn} do
    for path <- [@as, @rs] do
      result = conn |> put_req_header("origin", "https://app.example.org") |> get(@origin <> path)
      assert json_response(result, 200)
      assert get_resp_header(result, "content-type") == ["application/json; charset=utf-8"]
      assert get_resp_header(result, "cache-control") == ["public, max-age=300"]
      assert get_resp_header(result, "access-control-allow-origin") == ["*"]
      assert get_resp_header(result, "access-control-allow-credentials") == []
      assert get_resp_header(result, "set-cookie") == []
      assert get_resp_header(result, "location") == []
      assert get_resp_header(result, "dpop-nonce") == []
      assert get_resp_header(result, "x-content-type-options") == ["nosniff"]
      head = head(conn, @origin <> path)
      assert response(head, 200) == ""

      assert get_resp_header(head, "content-length") == [
               Integer.to_string(byte_size(result.resp_body))
             ]
    end
  end

  test "host and forwarding headers cannot choose an issuer", %{conn: conn} do
    result =
      conn
      |> put_req_header("x-forwarded-host", "evil.example.com")
      |> put_req_header("x-forwarded-proto", "http")
      |> put_req_header("forwarded", "host=evil.example.com;proto=http")
      |> get(@origin <> @as)

    assert json_response(result, 200)["issuer"] == @origin

    for path <- [@as, @rs] do
      denied = get(conn, "https://evil.example.com" <> path)
      assert json_response(denied, 404) == %{"error" => "not_found"}
      assert get_resp_header(denied, "cache-control") == ["no-store"]
      refute denied.resp_body =~ "evil.example.com"
    end

    configure(scheme: "https", host: "pds.example.com", port: 8443)

    assert get(conn, "https://pds.example.com:8443" <> @as)
           |> json_response(200)
           |> Map.fetch!("issuer") == "https://pds.example.com:8443"
  end

  test "insecure or path-prefixed deployment fails, with explicit localhost development opt-in",
       %{conn: conn} do
    configure(scheme: "http", host: "pds.example.com", port: 80)
    assert get(conn, "http://pds.example.com" <> @as).status == 503
    configure(scheme: "https", host: "pds.example.com", port: 443, path: "/prefix")
    assert get(conn, @origin <> @as).status == 503
    configure(scheme: "http", host: "localhost", port: 4000)
    Application.put_env(:atoll, :localhost_dids_enabled, false)
    assert get(conn, "http://localhost:4000" <> @as).status == 503
    Application.put_env(:atoll, :localhost_dids_enabled, true)

    assert get(conn, "http://localhost:4000" <> @as) |> json_response(200) |> Map.fetch!("issuer") ==
             "http://localhost:4000"

    configure(scheme: "http", host: "127.0.0.1", port: 4000)
    assert get(conn, "http://127.0.0.1:4000" <> @as).status == 503
  end

  test "preflight supports only metadata reads and bounded known headers", %{conn: conn} do
    for path <- [@as, @rs], method <- ["GET", "HEAD"] do
      result =
        conn
        |> put_req_header("origin", "https://app.example.org")
        |> put_req_header("access-control-request-method", method)
        |> put_req_header("access-control-request-headers", "Accept, Content-Type")
        |> options(@origin <> path)

      assert response(result, 204) == ""
      assert get_resp_header(result, "access-control-allow-methods") == ["GET, HEAD"]
      assert get_resp_header(result, "access-control-max-age") == ["600"]
      assert get_resp_header(result, "access-control-allow-credentials") == []
    end

    for {method, headers} <- [
          {"POST", "accept"},
          {"GET", "authorization"},
          {"GET", "x-untrusted"},
          {"GET", String.duplicate("x", 1025)}
        ] do
      assert conn
             |> put_req_header("origin", "https://app.example.org")
             |> put_req_header("access-control-request-method", method)
             |> put_req_header("access-control-request-headers", headers)
             |> options(@origin <> @as)
             |> json_response(400)
    end

    assert options(conn, @origin <> @rs).status == 204
  end

  test "canonical paths, query rejection and method checks precede body parsing", %{conn: conn} do
    for path <- [@as, @rs] do
      for suffix <- ["?issuer=https://evil.example.org", "?x=1&x=2"] do
        assert get(conn, @origin <> path <> suffix).status == 400
      end

      encoded = String.replace(path, "/.well-known/", "/%2ewell-known/")
      assert get(conn, @origin <> encoded).status == 400

      result =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(@origin <> path, "{broken")

      assert result.status == 405
      assert get_resp_header(result, "allow") == ["GET, HEAD, OPTIONS"]
    end
  end

  defp configure(url) do
    settings = Application.fetch_env!(:atoll, AtollWeb.Endpoint)
    AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, Keyword.put(settings, :url, url)}], [])
  end
end
