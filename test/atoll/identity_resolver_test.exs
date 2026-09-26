defmodule Atoll.IdentityResolverTest do
  use ExUnit.Case, async: true
  alias Atoll.Identity.Resolver
  alias Atoll.{Multikey, SigningKey}
  @did "did:web:alice.example.com"

  setup do
    key = SigningKey.generate()
    {:ok, multikey} = Multikey.encode(key.curve, key.public)

    doc = %{
      "id" => @did,
      "verificationMethod" => [
        %{
          "id" => "#atproto",
          "controller" => @did,
          "type" => "Multikey",
          "publicKeyMultibase" => multikey
        }
      ],
      "service" => [
        %{
          "id" => "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => "https://pds.example.com"
        }
      ]
    }

    %{doc: doc}
  end

  test "constructs only supported method URLs" do
    plc = "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
    assert Resolver.resolution_url(plc) == {:ok, "https://plc.directory/" <> plc}

    assert Resolver.resolution_url(@did) ==
             {:ok, "https://alice.example.com/.well-known/did.json"}

    assert Resolver.resolution_url("did:key:abc") == {:error, :unsupported_did_method}

    for did <- [
          nil,
          "bad",
          "did:plc:short",
          "did:web:localhost",
          "did:web:example.com:path",
          "did:web:example.com%3A443",
          "did:web:EXAMPLE.com",
          "did:web:127.0.0.1",
          "did:web:internal.local"
        ] do
      assert Resolver.resolution_url(did) == {:error, :invalid_did}
    end
  end

  test "pins the address and preserves hostname for HTTP and TLS", %{doc: doc} do
    plug = fn conn ->
      assert conn.host == "8.8.8.8"
      assert Plug.Conn.get_req_header(conn, "host") == ["alice.example.com"]
      assert conn.request_path == "/.well-known/did.json"
      Req.Test.json(conn, doc)
    end

    request =
      Req.new(plug: plug)
      |> Req.Request.append_request_steps(
        inspect_options: fn req ->
          assert req.options.connect_options[:hostname] == "alice.example.com"
          assert req.options.redirect == false
          assert req.options.raw == true
          req
        end
      )

    assert {:ok, identity} =
             Resolver.resolve(@did, request: request, lookup: fn _ -> {:ok, {8, 8, 8, 8}} end)

    assert identity.did == @did
    assert identity.document == doc
  end

  test "blocks non-public destinations before making requests" do
    for ip <- [
          {127, 0, 0, 1},
          {10, 0, 0, 1},
          {169, 254, 169, 254},
          {172, 16, 0, 1},
          {192, 168, 1, 1},
          {100, 64, 0, 1},
          {0, 0, 0, 0},
          {224, 0, 0, 1},
          {198, 18, 0, 1},
          {0, 0, 0, 0, 0, 0, 0, 1}
        ] do
      refute Resolver.public_ipv4?(ip)

      assert Resolver.resolve(@did, lookup: fn _ -> {:ok, ip} end) ==
               {:error, :unsafe_destination}
    end

    assert Resolver.resolve(@did, lookup: fn _ -> {:error, :nxdomain} end) ==
             {:error, :resolution_failed}
  end

  test "rejects redirects, oversized bodies, bad JSON and mismatched identities", %{doc: doc} do
    for {status, body, expected} <- [
          {302, "", :resolution_failed},
          {404, "", :did_not_found},
          {200, String.duplicate("x", 262_145), :did_document_too_large},
          {200, "invalid", :invalid_did_document},
          {200, Jason.encode!(%{doc | "id" => "did:web:other.example.com"}),
           :invalid_did_document}
        ] do
      request = Req.new(plug: fn conn -> Plug.Conn.send_resp(conn, status, body) end)

      assert Resolver.resolve(@did, request: request, lookup: fn _ -> {:ok, {8, 8, 8, 8}} end) ==
               {:error, expected}
    end
  end
end
