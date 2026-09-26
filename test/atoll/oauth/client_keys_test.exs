defmodule Atoll.OAuth.ClientKeysTest do
  use ExUnit.Case, async: true
  alias Atoll.OAuth.ClientKeys
  @id "https://app.example.com/metadata.json"
  @jwks "https://keys.example.com/jwks.json"

  setup do
    key = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, public} = JOSE.JWK.to_public_map(key)
    %{key: key, public: Map.put(public, "kid", "first")}
  end

  defp metadata(source) do
    Map.merge(
      %{
        "client_id" => @id,
        "grant_types" => ["authorization_code"],
        "response_types" => ["code"],
        "scope" => "atproto",
        "redirect_uris" => ["https://app.example.com/callback"],
        "dpop_bound_access_tokens" => true,
        "token_endpoint_auth_method" => "private_key_jwt"
      },
      source
    )
  end

  defp fetch(keys) do
    options = [
      lookup: fn "app.example.com" -> {:ok, {8, 8, 8, 8}} end,
      request:
        Req.new(
          plug: fn conn -> Req.Test.json(conn, metadata(%{"jwks" => %{"keys" => keys}})) end
        )
    ]

    ClientKeys.fetch(@id, options)
  end

  test "inline keys produce public-only JOSE verification material with stable bindings", c do
    assert {:ok, %{metadata: meta, keys: %{"first" => advertised}}} = fetch([c.public])
    assert meta["client_id"] == @id
    assert advertised.kid == "first"
    assert advertised.alg == "ES256"
    assert advertised.jkt == JOSE.JWK.thumbprint(c.key)
    {_, public} = JOSE.JWK.to_map(advertised.jwk)
    assert Map.keys(public) |> Enum.sort() == ~w(crv kty x y)

    {_, assertion} =
      JOSE.JWT.sign(c.key, %{"alg" => "ES256"}, %{"sub" => @id}) |> JOSE.JWS.compact()

    assert {true, _, _} = JOSE.JWT.verify_strict(advertised.jwk, ["ES256"], assertion)
  end

  test "rejects private material, ambiguous kids, wrong algorithms, use, and malformed points",
       c do
    {_, private} = JOSE.JWK.to_map(c.key)
    zero = Base.url_encode64(<<0::256>>, padding: false)

    malformed = [
      Map.put(private, "kid", "first"),
      Map.delete(c.public, "kid"),
      Map.put(c.public, "kid", ""),
      Map.put(c.public, "kid", String.duplicate("k", 257)),
      Map.put(c.public, "kid", "line\nbreak"),
      Map.put(c.public, "alg", "HS256"),
      Map.put(c.public, "use", "enc"),
      Map.put(c.public, "key_ops", ["sign", "verify"]),
      Map.put(c.public, "key_ops", nil),
      Map.put(c.public, "crv", "secp256k1"),
      Map.put(c.public, "kty", "RSA"),
      Map.put(c.public, "x", c.public["x"] <> "="),
      Map.put(c.public, "x", zero) |> Map.put("y", zero),
      Map.put(c.public, "y", Base.url_encode64(<<1::256>>, padding: false)),
      Map.put(c.public, "jku", "https://other.example.com/keys"),
      Map.put(c.public, "x5u", "https://other.example.com/cert"),
      Map.put(c.public, "k", "secret")
    ]

    for invalid <- malformed do
      assert {:error, :invalid_client_keys} = fetch([invalid])
    end

    assert {:error, :invalid_client_keys} = fetch([c.public, c.public])
    assert {:error, :invalid_client_keys} = fetch([c.public, Map.put(c.public, "x", zero)])
    assert {:ok, %{keys: keys}} = fetch([])
    assert keys == %{}

    assert {:error, :invalid_client_keys} =
             fetch(Enum.map(1..33, &Map.put(c.public, "kid", "key-#{&1}")))
  end

  test "remote keys use the same bounded pinned HTTPS transport and are fetched freshly", c do
    state = start_supervised!({Agent, fn -> [c.public] end})
    parent = self()

    request =
      Req.new(
        plug: fn conn ->
          assert conn.host == "8.8.8.8"
          assert Plug.Conn.get_req_header(conn, "authorization") == []

          case Plug.Conn.get_req_header(conn, "host") do
            ["app.example.com"] ->
              send(parent, :metadata)
              Req.Test.json(conn, metadata(%{"jwks_uri" => @jwks}))

            ["keys.example.com"] ->
              assert conn.request_path == "/jwks.json"
              send(parent, :keys)
              Req.Test.json(conn, %{"keys" => Agent.get(state, & &1)})
          end
        end
      )
      |> Req.Request.append_request_steps(
        check_hostname: fn req ->
          assert req.options.connect_options[:hostname] in ["app.example.com", "keys.example.com"]
          assert req.options.redirect == false
          assert req.options.raw == true
          req
        end
      )

    opts = [request: request, lookup: fn _ -> {:ok, {8, 8, 8, 8}} end]
    assert {:ok, %{keys: initial}} = ClientKeys.fetch(@id, opts)
    assert_receive :metadata
    assert_receive :keys
    {_, other} = JOSE.JWK.generate_key({:ec, :secp256r1}) |> JOSE.JWK.to_public_map()
    other = Map.put(other, "kid", "second")
    Agent.update(state, fn _ -> [c.public, other] end)
    assert {:ok, %{keys: rotated}} = ClientKeys.fetch(@id, opts)
    assert map_size(rotated) == 2
    assert rotated["first"].jkt == initial["first"].jkt
    Agent.update(state, fn _ -> [other] end)
    assert {:ok, %{keys: removed}} = ClientKeys.fetch(@id, opts)
    refute Map.has_key?(removed, "first")
    Agent.update(state, fn _ -> [Map.put(other, "kid", "first")] end)
    assert {:ok, %{keys: replaced}} = ClientKeys.fetch(@id, opts)
    refute replaced["first"].jkt == initial["first"].jkt
    Agent.update(state, fn _ -> [] end)
    assert {:ok, %{keys: keys}} = ClientKeys.fetch(@id, opts)
    assert keys == %{}
  end

  test "remote JWKS rejects redirects, duplicate members, large bodies, and private destinations",
       c do
    body = Jason.encode!(%{"keys" => [c.public]})

    for {status, type, encoding, payload} <- [
          {302, "application/json", nil, body},
          {201, "application/json", nil, body},
          {200, "text/plain", nil, body},
          {200, "application/json", "gzip", body},
          {200, "application/json", nil, String.duplicate(" ", 65_537) <> body},
          {200, "application/json", nil,
           "{\"keys\":[],\"keys\":[" <> Jason.encode!(c.public) <> "]}"},
          {200, "application/json", nil,
           String.replace(body, "\"kid\":", "\"kid\":\"other\",\"kid\":")}
        ] do
      request =
        Req.new(
          plug: fn conn ->
            if conn.request_path == "/metadata.json" do
              Req.Test.json(conn, metadata(%{"jwks_uri" => @jwks}))
            else
              conn = Plug.Conn.put_resp_header(conn, "content-type", type)

              conn =
                if encoding,
                  do: Plug.Conn.put_resp_header(conn, "content-encoding", encoding),
                  else: conn

              conn
              |> Plug.Conn.put_resp_header("location", @jwks)
              |> Plug.Conn.send_resp(status, payload)
            end
          end
        )

      assert {:error, :invalid_client_keys} =
               ClientKeys.fetch(@id, request: request, lookup: fn _ -> {:ok, {8, 8, 8, 8}} end)
    end

    request =
      Req.new(
        plug: fn conn ->
          assert conn.request_path == "/metadata.json"
          Req.Test.json(conn, metadata(%{"jwks_uri" => @jwks}))
        end
      )

    lookup = fn
      "app.example.com" -> {:ok, {8, 8, 8, 8}}
      "keys.example.com" -> {:ok, {127, 0, 0, 1}}
    end

    assert {:error, :invalid_client_keys} =
             ClientKeys.fetch(@id, request: request, lookup: lookup)
  end

  test "public clients cannot be authenticated through advertised keys", c do
    request =
      Req.new(
        plug: fn conn ->
          doc =
            metadata(%{"jwks" => %{"keys" => [c.public]}})
            |> Map.put("token_endpoint_auth_method", "none")

          Req.Test.json(conn, doc)
        end
      )

    assert {:error, :invalid_client_keys} =
             ClientKeys.fetch(@id, request: request, lookup: fn _ -> {:ok, {8, 8, 8, 8}} end)
  end
end
