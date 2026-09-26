defmodule Atoll.OAuth.ClientMetadataTest do
  use ExUnit.Case, async: true
  alias Atoll.OAuth.ClientMetadata
  @id "https://app.example.com/oauth-client-metadata.json"

  defp document do
    %{
      "client_id" => @id,
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "scope" => "atproto transition:generic",
      "redirect_uris" => ["https://app.example.com/callback?flow=login"],
      "dpop_bound_access_tokens" => true
    }
  end

  defp opts(plug) do
    [request: Req.new(plug: plug), lookup: fn "app.example.com" -> {:ok, {8, 8, 8, 8}} end]
  end

  defp fetch(doc, id \\ @id),
    do: ClientMetadata.fetch(id, opts(fn conn -> Req.Test.json(conn, doc) end))

  test "fresh retrieval pins public DNS and preserves HTTP and TLS hostname" do
    doc = document()
    parent = self()

    request =
      Req.new(
        plug: fn conn ->
          assert conn.host == "8.8.8.8"
          assert Plug.Conn.get_req_header(conn, "host") == ["app.example.com"]
          assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]
          assert Plug.Conn.get_req_header(conn, "accept-encoding") == ["identity"]
          assert conn.request_path == "/oauth-client-metadata.json"
          send(parent, :fetched)
          Req.Test.json(conn, doc)
        end
      )
      |> Req.Request.append_request_steps(
        inspect_transport: fn req ->
          assert req.options.connect_options[:hostname] == "app.example.com"
          assert req.options.redirect == false
          assert req.options.retry == false
          assert req.options.raw == true
          assert req.options.request_timeout == 5000
          req
        end
      )

    options = [request: request, lookup: fn _ -> {:ok, {8, 8, 8, 8}} end]
    assert {:ok, meta} = ClientMetadata.fetch(@id, options)
    assert_receive :fetched
    assert meta["application_type"] == "web"
    assert meta["token_endpoint_auth_method"] == "none"
    assert {:ok, ^meta} = ClientMetadata.fetch(@id, options)
    assert_receive :fetched
  end

  test "rejects unsafe client IDs before DNS or HTTP and non-public resolved addresses before HTTP" do
    options = [
      lookup: fn _ -> flunk("unexpected DNS") end,
      request: Req.new(plug: fn _ -> flunk("unexpected HTTP") end)
    ]

    for id <- [
          nil,
          "",
          "http://app.example.com/meta",
          "http://localhost:80",
          @id <> "#fragment",
          "https://app.example.com:443/meta",
          "https://user@app.example.com/meta",
          "https://app.example.com:8443/meta",
          "https://app.example.com\\@127.0.0.1/meta",
          "https://app.example.com/%zz",
          "https://app.example.com/\nmeta"
        ] do
      assert {:error, :invalid_client_metadata} = ClientMetadata.fetch(id, options)
    end

    for address <- [{127, 0, 0, 1}, {10, 0, 0, 1}, {169, 254, 169, 254}, {0, 0, 0, 0, 0, 0, 0, 1}] do
      assert {:error, :invalid_client_metadata} =
               ClientMetadata.fetch(
                 @id,
                 Keyword.put(options, :lookup, fn _ -> {:ok, address} end)
               )
    end
  end

  test "requires exact 200 JSON, identity encoding, and a bounded unique-member JSON object" do
    body = Jason.encode!(document())

    for {status, type, encoding, payload} <- [
          {201, "application/json", nil, body},
          {302, "application/json", nil, body},
          {200, "text/html", nil, body},
          {200, "application/json", "gzip", body},
          {200, "application/json", nil, "[]"},
          {200, "application/json", nil, "{"},
          {200, "application/json", nil,
           String.replace(body, "{", "{\"client_id\":\"duplicate\",", global: false)},
          {200, "application/json", nil, String.duplicate(" ", 65_537) <> body},
          {200, "application/json", nil,
           String.replace(body, "{", "{\"extension\":{\"x\":1,\"x\":2},", global: false)},
          {200, "application/json", nil,
           String.replace(
             body,
             "{",
             "{\"deep\":" <> String.duplicate("[", 20) <> "0" <> String.duplicate("]", 20) <> ",",
             global: false
           )}
        ] do
      options =
        opts(fn conn ->
          conn = Plug.Conn.put_resp_header(conn, "content-type", type)

          conn =
            if encoding,
              do: Plug.Conn.put_resp_header(conn, "content-encoding", encoding),
              else: conn

          conn = Plug.Conn.put_resp_header(conn, "location", "https://app.example.com/other")
          Plug.Conn.send_resp(conn, status, payload)
        end)

      assert {:error, :invalid_client_metadata} = ClientMetadata.fetch(@id, options)
    end

    assert {:ok, _} =
             ClientMetadata.fetch(
               @id,
               opts(fn conn ->
                 conn
                 |> Plug.Conn.put_resp_header("content-type", "Application/JSON; charset=utf-8")
                 |> Plug.Conn.send_resp(200, body)
               end)
             )
  end

  test "requires exact client identity, required declarations, and supported profile values" do
    doc = document()

    for field <- Map.keys(doc) do
      assert {:error, :invalid_client_metadata} = fetch(Map.delete(doc, field))
    end

    for {key, value} <- [
          {"client_id", @id <> "?different"},
          {"application_type", "desktop"},
          {"dpop_bound_access_tokens", "true"},
          {"grant_types", ["implicit"]},
          {"grant_types", ["authorization_code", "password"]},
          {"response_types", ["code", "token"]},
          {"redirect_uris", []},
          {"redirect_uris", [123]},
          {"scope", "transition:generic"},
          {"scope", "atproto  transition:generic"},
          {"scope", "atproto\nadmin"},
          {"scope", "atproto atproto"},
          {"token_endpoint_auth_method", "client_secret_basic"},
          {"token_endpoint_auth_signing_alg", "none"},
          {"token_endpoint_auth_signing_alg", "RS256"},
          {"client_uri", "https://different.example.com"},
          {"logo_uri", "http://app.example.com/logo"}
        ] do
      assert {:error, :invalid_client_metadata} = fetch(Map.put(doc, key, value))
    end
  end

  test "web redirects and requested scopes require exact declared membership" do
    assert {:ok, meta} = fetch(document())
    assert ClientMetadata.redirect_allowed?(meta, "https://app.example.com/callback?flow=login")
    refute ClientMetadata.redirect_allowed?(meta, "https://app.example.com/callback?flow=other")
    refute ClientMetadata.redirect_allowed?(meta, "https://app.example.com/callback")
    assert ClientMetadata.scopes_allowed?(meta, "atproto")
    assert ClientMetadata.scopes_allowed?(meta, "transition:generic atproto")
    refute ClientMetadata.scopes_allowed?(meta, "atproto transition:email")
    refute ClientMetadata.scopes_allowed?(meta, "transition:generic")

    assert {:ok, _} =
             fetch(Map.put(document(), "redirect_uris", ["https://callback.example.com:8443/cb"]))

    for callback <- [
          "http://app.example.com/cb",
          "https://app.example.com:443/cb",
          "https://user@app.example.com/cb",
          "https://app.example.com/cb#fragment",
          "com.example.app:/cb"
        ] do
      assert {:error, :invalid_client_metadata} =
               fetch(Map.put(document(), "redirect_uris", [callback]))
    end
  end

  test "native redirects require reverse-domain custom scheme or same HTTPS origin" do
    doc = Map.put(document(), "application_type", "native")

    for callback <- ["com.example.app:/callback", "https://app.example.com/callback"] do
      assert {:ok, _} = fetch(Map.put(doc, "redirect_uris", [callback]))
    end

    for callback <- [
          "com.example.other:/callback",
          "com.example.app://callback",
          "com.example.app:callback",
          "https://other.example.com/callback",
          "https://app.example.com:8443/callback",
          "http://127.0.0.1/callback"
        ] do
      assert {:error, :invalid_client_metadata} = fetch(Map.put(doc, "redirect_uris", [callback]))
    end
  end

  test "confidential clients require one key source, retained as unverified declaration" do
    doc = Map.put(document(), "token_endpoint_auth_method", "private_key_jwt")
    assert {:error, :invalid_client_metadata} = fetch(doc)
    remote = Map.put(doc, "jwks_uri", "https://keys.example.com/jwks.json")
    assert {:ok, meta} = fetch(remote)
    assert meta["jwks_uri"] == remote["jwks_uri"]

    {_, key} = JOSE.JWK.generate_key({:ec, :secp256r1}) |> JOSE.JWK.to_public_map()
    inline = Map.put(doc, "jwks", %{"keys" => [key]})
    assert {:ok, _} = fetch(inline)
    assert {:error, :invalid_client_metadata} = fetch(Map.put(remote, "jwks", inline["jwks"]))
    assert {:ok, _} = fetch(Map.put(doc, "jwks", %{"keys" => []}))

    assert {:error, :invalid_client_metadata} =
             fetch(Map.put(doc, "jwks_uri", "http://keys.example.com/jwks"))
  end
end
