defmodule Atoll.OAuth.LocalhostClientTest do
  use ExUnit.Case, async: true
  alias Atoll.OAuth.{ClientMetadata, ClientKeys}

  defp options,
    do: [
      lookup: fn _ -> flunk("localhost metadata must not resolve DNS") end,
      request: Req.new(plug: fn _ -> flunk("localhost metadata must not fetch HTTP") end)
    ]

  test "bare localhost IDs synthesize public native metadata without network IO" do
    for id <- ["http://localhost", "http://localhost/", "http://localhost?"] do
      assert {:ok, doc} = ClientMetadata.fetch(id, options())
      assert doc["client_id"] == id
      assert doc["application_type"] == "native"
      assert doc["token_endpoint_auth_method"] == "none"
      assert doc["dpop_bound_access_tokens"] == true
      assert doc["scope"] == "atproto"
      assert doc["redirect_uris"] == ["http://127.0.0.1/", "http://[::1]/"]
      assert doc["grant_types"] == ["authorization_code", "refresh_token"]
      assert doc["response_types"] == ["code"]
      assert ClientMetadata.redirect_allowed?(doc, "http://127.0.0.1:3000/")
      assert ClientMetadata.redirect_allowed?(doc, "http://[::1]:9000/")
      refute ClientMetadata.redirect_allowed?(doc, "http://localhost:3000/")
      refute ClientMetadata.redirect_allowed?(doc, "http://127.0.0.1:3000/callback")
      assert {:error, :invalid_client_keys} = ClientKeys.fetch(id, options())
    end
  end

  test "repeated callbacks and scope are decoded, but only callback ports are ignored" do
    id =
      "http://localhost/?" <>
        URI.encode_query([
          {"redirect_uri", "http://127.0.0.1:3000/callback?flow=local"},
          {"redirect_uri", "http://[::1]/other"},
          {"scope", "atproto transition:generic"}
        ])

    assert {:ok, doc} = ClientMetadata.fetch(id, options())
    assert doc["scope"] == "atproto transition:generic"
    assert ClientMetadata.redirect_allowed?(doc, "http://127.0.0.1:9000/callback?flow=local")
    assert ClientMetadata.redirect_allowed?(doc, "http://[::1]:3000/other")

    for uri <- [
          "http://127.0.0.1:9000/callback?flow=other",
          "http://127.0.0.1:9000/callback",
          "http://127.0.0.1:9000/callback/",
          "http://[::1]:9000/callback?flow=local",
          "https://127.0.0.1:9000/callback?flow=local",
          "http://127.0.0.1:9000/%63allback?flow=local"
        ] do
      refute ClientMetadata.redirect_allowed?(doc, uri)
    end

    # An untrusted extension on ordinary metadata cannot enable loopback port matching.
    doc = %{
      "client_id" => "https://app.example.com/meta",
      "redirect_uris" => ["http://127.0.0.1:3000/"],
      "localhost" => true
    }

    refute ClientMetadata.redirect_allowed?(doc, "http://127.0.0.1:9000/")
  end

  test "rejects ambiguous IDs, parameter injection, duplicate scopes and malformed encodings" do
    for id <- [
          "http://localhost:80",
          "http://localhost:3000/",
          "http://user@localhost/",
          "http://localhost/#fragment",
          "http://localhost/path",
          "http://localhost/./",
          "http://localhost//",
          "http://localhost.evil/",
          "http://127.0.0.1/",
          "http://[::1]/",
          "http://local%68ost/",
          "http://localhost?scope=atproto&sc%6fpe=atproto",
          "http://localhost?scope=",
          "http://localhost?scope=transition%3Ageneric",
          "http://localhost?scope=atproto+atproto",
          "http://localhost?scope=%FF",
          "http://localhost?scope=%ZZ",
          "http://localhost?scope",
          "http://localhost?token_endpoint_auth_method=private_key_jwt",
          "http://localhost?jwks_uri=https%3A%2F%2Fexample.com",
          "http://localhost?scope=atproto&",
          "http://localhost?" <> String.duplicate("x", 2048)
        ] do
      assert {:error, :invalid_client_metadata} = ClientMetadata.fetch(id, options())
    end
  end

  test "callback declarations reject non-loopback, ambiguous authorities and unsafe paths" do
    for callback <- [
          "http://localhost:3000/",
          "http://127.1/",
          "http://127.0.0.2/",
          "http://2130706433/",
          "http://[::ffff:127.0.0.1]/",
          "https://127.0.0.1/",
          "http://example.com/",
          "http://127.0.0.1.evil/",
          "http://user@127.0.0.1/",
          "http://127.0.0.1:0/",
          "http://127.0.0.1:65536/",
          "http://127.0.0.1/#",
          "http://127.0.0.1/a/../callback",
          "http://127.0.0.1/%2e%2e/callback",
          "http://127.0.0.1\\evil/"
        ] do
      id = "http://localhost?" <> URI.encode_query(%{"redirect_uri" => callback})
      assert {:error, :invalid_client_metadata} = ClientMetadata.fetch(id, options())
    end

    params = for _ <- 1..33, do: {"redirect_uri", "http://127.0.0.1/"}

    assert {:error, :invalid_client_metadata} =
             ClientMetadata.fetch("http://localhost?" <> URI.encode_query(params), options())
  end
end
