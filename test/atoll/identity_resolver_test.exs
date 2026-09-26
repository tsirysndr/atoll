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

  test "pins IPv6 literals with original HTTP and TLS hostnames for DID and handle fetches", %{
    doc: doc
  } do
    address = {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}

    request =
      Req.new(
        plug: fn conn ->
          assert conn.host == "2606:4700:4700::1111"
          assert Plug.Conn.get_req_header(conn, "host") == ["alice.example.com"]

          case conn.request_path do
            "/.well-known/did.json" -> Req.Test.json(conn, doc)
            "/.well-known/atproto-did" -> Plug.Conn.send_resp(conn, 200, @did)
          end
        end
      )
      |> Req.Request.append_request_steps(
        inspect_ipv6: fn req ->
          assert URI.to_string(req.url) =~ "https://[2606:4700:4700::1111]/"
          assert req.options.connect_options[:hostname] == "alice.example.com"
          assert req.options.connect_options[:transport_opts] == [inet6: true, inet4: false]
          assert req.options.redirect == false
          req
        end
      )

    opts = [request: request, lookup: fn _ -> {:ok, address} end]
    assert {:ok, %{document: ^doc}} = Resolver.resolve(@did, opts)
    assert {:ok, @did} = Resolver.fetch_handle("alice.example.com", opts)
  end

  test "rejects IPv6 special ranges and malformed addresses before HTTP" do
    denied = [
      "::",
      "::1",
      "::ffff:127.0.0.1",
      "::ffff:8.8.8.8",
      "::8.8.8.8",
      "64:ff9b::a00:1",
      "64:ff9b:1::1",
      "100::1",
      "100:0:0:1::1",
      "2001::1",
      "2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff",
      "2001:2::1",
      "2001:10::1",
      "2001:20::1",
      "2001:db8::1",
      "2002:7f00:1::1",
      "3fff::1",
      "3fff:fff::1",
      "5f00::1",
      "fc00::1",
      "fdff::1",
      "fe80::1",
      "febf::1",
      "fec0::1",
      "ff02::1"
    ]

    for text <- denied do
      {:ok, address} = :inet.parse_address(String.to_charlist(text))
      refute Resolver.public_ipv6?(address), text

      assert {:error, :unsafe_destination} =
               Resolver.resolve(@did,
                 lookup: fn _ -> {:ok, address} end,
                 request: Req.new(plug: fn _ -> flunk("unsafe IPv6 request") end)
               )
    end

    for bad <- [
          nil,
          "2606:4700::1",
          {0x2606, 0, 0, 0, 0, 0, 0, 65_536},
          {0x2606, 0, 0, 0, 0, 0, 0, -1},
          {0x2606, 0, 0, 0, 0, 0, 0, 1.5}
        ] do
      refute Resolver.public_ipv6?(bad)
    end

    for text <- ["2001:200::1", "2001:4860:4860::8888", "2606:4700:4700::1111", "3fff:1000::1"] do
      {:ok, address} = :inet.parse_address(String.to_charlist(text))
      assert Resolver.public_ipv6?(address), text
    end
  end

  test "DNS selects public answers and falls back to AAAA within one deadline" do
    ipv6 = {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}

    assert {:ok, {8, 8, 8, 8}} =
             Resolver.lookup("alice.example.com", fn
               ~c"alice.example.com", :inet, timeout ->
                 assert timeout in 1..3000
                 {:ok, [{10, 0, 0, 1}, {8, 8, 8, 8}]}

               _, :inet6, _ ->
                 flunk("IPv4 already resolved")
             end)

    parent = self()

    assert {:ok, ^ipv6} =
             Resolver.lookup("alice.example.com", fn
               _, :inet, timeout ->
                 send(parent, {:v4_budget, timeout})
                 {:ok, [{127, 0, 0, 1}]}

               _, :inet6, timeout ->
                 send(parent, {:v6_budget, timeout})
                 {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}, ipv6]}
             end)

    assert_receive {:v4_budget, v4}
    assert_receive {:v6_budget, v6}
    assert v6 > 0 and v6 <= v4 and v4 <= 3000

    assert {:ok, ^ipv6} =
             Resolver.lookup("alice.example.com", fn
               _, :inet, _ -> {:error, :nxdomain}
               _, :inet6, _ -> {:ok, [ipv6]}
             end)

    assert {:error, :dns_failed} =
             Resolver.lookup("alice.example.com", fn
               _, :inet, _ -> {:ok, [{192, 168, 1, 1}]}
               _, :inet6, _ -> {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]}
             end)
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
