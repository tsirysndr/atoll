defmodule Atoll.LocalhostIdentityTest do
  use ExUnit.Case, async: false
  alias Atoll.Identity.{Document, Localhost, Resolver}

  setup do
    previous =
      Map.new(
        [:localhost_dids_enabled, :pds, :server_identity_key],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)
    Application.put_env(:atoll, :localhost_dids_enabled, true)

    on_exit(fn ->
      AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], [])

      for {name, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end
    end)

    :ok
  end

  test "only explicit development/test opt-in can enable the exception" do
    for env <- [:dev, :test] do
      assert Localhost.parse_enabled!("true", env)
      refute Localhost.parse_enabled!(nil, env)
    end

    assert_raise RuntimeError, fn -> Localhost.parse_enabled!("true", :prod) end
    assert_raise RuntimeError, fn -> Localhost.parse_enabled!("yes", :dev) end
    refute Localhost.parse_enabled!("false", :prod)
    Application.put_env(:atoll, :localhost_dids_enabled, false)

    for did <- ["did:web:localhost", "did:web:localhost%3A4000"] do
      assert {:error, :invalid_did} = Resolver.resolve_document(did)
    end

    refute Localhost.endpoint?("http://localhost:4000")
  end

  test "allows literal localhost and canonical encoded ports but no paths or address aliases" do
    assert {:ok, "http://localhost/.well-known/did.json"} =
             Resolver.resolution_url("did:web:localhost")

    assert {:ok, "http://localhost:4000/.well-known/did.json"} =
             Resolver.resolution_url("did:web:localhost%3A4000")

    assert {:ok, "http://localhost:4000/.well-known/did.json"} =
             Resolver.resolution_url("did:web:localhost%3a4000")

    for did <- [
          "did:web:localhost:4000",
          "did:web:localhost%3A0",
          "did:web:localhost%3A65536",
          "did:web:localhost%3A04000",
          "did:web:localhost%3A+4000",
          "did:web:LOCALHOST",
          "did:web:localhost:path",
          "did:web:127.0.0.1",
          "did:web:localhost%3A4000:path",
          "did:web:localhost%3A4000?x",
          "did:web:localhost%3A4000#x",
          "did:web:sub.localhost"
        ] do
      assert {:error, :invalid_did} = Resolver.resolution_url(did), did
    end

    assert {:error, :invalid_handle} = Resolver.fetch_handle("localhost", [])
    assert {:error, :invalid_handle} = Resolver.fetch_handle("localhost%3A4000", [])
  end

  test "loopback exception never applies to public names resolving to private addresses" do
    for host <- ["localhost.example.com", "alice.example.com"] do
      assert {:error, :unsafe_destination} =
               Resolver.resolve_document("did:web:" <> host,
                 lookup: fn _ -> {:ok, {127, 0, 0, 1}} end,
                 request: Req.new(plug: fn _ -> flunk("private destination") end)
               )
    end

    for endpoint <- [
          "http://127.0.0.1:4000",
          "http://sub.localhost:4000",
          "http://localhost:0",
          "http://localhost/path",
          "http://user@localhost",
          "http://localhost?x",
          "http://localhost#x"
        ] do
      refute Localhost.endpoint?(endpoint), endpoint
    end
  end

  test "pins localhost directly, includes port in Host, checks document id and refuses redirects" do
    did = "did:web:localhost%3A4000"

    for {status, body, result} <- [
          {200, Jason.encode!(%{"id" => did}), {:ok, %{"id" => did}}},
          {200, Jason.encode!(%{"id" => "did:web:localhost"}), {:error, :invalid_did_document}},
          {302, "", {:error, :resolution_failed}}
        ] do
      request =
        Req.new(
          plug: fn conn ->
            assert conn.host == "127.0.0.1"
            assert conn.port == 4000
            assert conn.scheme == :http
            assert Plug.Conn.get_req_header(conn, "host") == ["localhost:4000"]

            conn
            |> Plug.Conn.put_resp_header("location", "http://127.0.0.1:1234")
            |> Plug.Conn.send_resp(status, body)
          end
        )

      assert ^result =
               Resolver.resolve_document(did,
                 lookup: fn _ -> flunk("localhost must not use DNS") end,
                 request: request
               )
    end
  end

  test "resolves a real development PDS DID document over loopback HTTP" do
    server = start_supervised!({Bandit, plug: AtollWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    did = "did:web:localhost%3A#{port}"
    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "http", host: "localhost", port: port)}
      ],
      []
    )

    Application.put_env(:atoll, :pds, did: did, available_user_domains: [])
    key = Atoll.SigningKey.generate()
    Application.put_env(:atoll, :server_identity_key, key)
    assert {:ok, identity} = Resolver.resolve(did, lookup: fn _ -> flunk("unexpected DNS") end)
    assert identity.did == did
    assert identity.pds == "http://localhost:#{port}"
    assert identity.signing_key.public == key.public
    refute Jason.encode!(identity.document) =~ Base.encode64(key.private)
    assert {:error, :not_found} = Atoll.Identity.Server.document("127.0.0.1")

    Application.put_env(:atoll, :localhost_dids_enabled, false)
    assert {:error, :invalid_did_document} = Document.parse(identity.document, did)
    assert {:error, :not_found} = Atoll.Identity.Server.document("localhost")
    assert {:error, :invalid_did} = Resolver.resolve(did)
  end
end
