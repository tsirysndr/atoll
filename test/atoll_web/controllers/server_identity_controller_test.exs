defmodule AtollWeb.ServerIdentityControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Multikey, SigningKey}
  @did "did:web:pds.example.com"
  @path "/.well-known/did.json"

  setup %{conn: conn} do
    previous = Map.new([:pds, :server_identity_key], &{&1, Application.fetch_env(:atoll, &1)})
    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "https", host: "pds.example.com", port: 443)}
      ],
      []
    )

    key = SigningKey.generate()
    Application.put_env(:atoll, :pds, did: @did, available_user_domains: [])
    Application.put_env(:atoll, :server_identity_key, key)

    on_exit(fn ->
      AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], [])

      for {name, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end
    end)

    %{conn: %{conn | host: "pds.example.com"}, key: key}
  end

  test "publishes a resolvable public service key without exposing private material", c do
    result = c.conn |> put_req_header("accept", "application/did+ld+json") |> get(@path)
    assert response(result, 200)
    assert get_resp_header(result, "content-type") == ["application/did+ld+json; charset=utf-8"]
    assert get_resp_header(result, "cache-control") == ["public, max-age=300"]
    assert get_resp_header(result, "access-control-allow-origin") == ["*"]
    doc = Jason.decode!(result.resp_body)
    assert doc["id"] == @did
    assert {:ok, %{curve: :k256, public: public}} = Atoll.Identity.Document.account_key(doc, @did)
    assert public == c.key.public
    {:ok, multikey} = Multikey.encode(:k256, c.key.public)

    assert doc["verificationMethod"] == [
             %{
               "id" => @did <> "#atproto",
               "type" => "Multikey",
               "controller" => @did,
               "publicKeyMultibase" => multikey
             }
           ]

    assert doc["service"] == [
             %{
               "id" => @did <> "#atproto_pds",
               "type" => "AtprotoPersonalDataServer",
               "serviceEndpoint" => "https://pds.example.com"
             }
           ]

    refute result.resp_body =~ Base.encode64(c.key.private)
    refute Map.has_key?(doc, "alsoKnownAs")
    assert response(get(c.conn, @path), 200) == result.resp_body
  end

  test "host and forwarded headers cannot replace the configured identity", c do
    assert response(get(%{c.conn | host: "other.example.com"}, @path), 404)

    result =
      c.conn
      |> put_req_header("x-forwarded-host", "attacker.example.com")
      |> put_req_header("x-forwarded-proto", "http")
      |> get(@path)

    assert Jason.decode!(response(result, 200))["id"] == @did
    Application.put_env(:atoll, :pds, did: "did:web:other.example.com")
    assert response(get(c.conn, @path), 404)

    for did <- [
          "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
          "did:web:pds.example.com:path",
          "did:web:localhost"
        ] do
      Application.put_env(:atoll, :pds, did: did)
      assert response(get(c.conn, @path), 404)
    end
  end

  test "missing stable key returns an uncached error rather than generating an identity", c do
    Application.delete_env(:atoll, :server_identity_key)
    result = get(c.conn, @path)
    assert response(result, 503) == "Server identity is not configured"
    assert get_resp_header(result, "cache-control") == ["no-store"]
  end

  test "runtime key parser derives a stable public key and rejects invalid secrets", c do
    assert Atoll.Identity.Server.key_from_env!(nil) == nil
    assert Atoll.Identity.Server.key_from_env!(Base.encode64(c.key.private)) == c.key

    for value <- [
          "secret",
          "",
          Base.encode64(<<0::256>>),
          Base.encode64(:binary.copy(<<255>>, 32)),
          Base.encode64(<<1, 2>>)
        ] do
      error = assert_raise RuntimeError, fn -> Atoll.Identity.Server.key_from_env!(value) end
      refute error.message =~ "secret"
    end
  end
end
