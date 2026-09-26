defmodule AtollWeb.IdentityResolutionControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Multikey, SigningKey}
  alias Atoll.Identity.Cache
  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  @handle "alice.example.com"
  @did_route "/xrpc/com.atproto.identity.resolveDid"
  @identity_route "/xrpc/com.atproto.identity.resolveIdentity"
  setup %{conn: conn} do
    previous = Application.fetch_env(:atoll, :identity_resolution_options)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atoll, :identity_resolution_options, value)
        :error -> Application.delete_env(:atoll, :identity_resolution_options)
      end
    end)

    doc = document(SigningKey.generate())
    Application.put_env(:atoll, :identity_resolution_options, options(doc))
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 68, div(id, 256), rem(id, 256)}}, doc: doc}
  end

  test "resolves remote DIDs and handles without a local account or authentication", c do
    result = get(c.conn, @did_route, %{did: @did})
    assert json_response(result, 200) == %{"didDoc" => c.doc}
    assert get_resp_header(result, "cache-control") == ["no-store"]

    for identifier <- [@did, String.upcase(@handle)] do
      assert get(c.conn, @identity_route, %{identifier: identifier}) |> json_response(200) == %{
               "did" => @did,
               "handle" => @handle,
               "didDoc" => c.doc
             }
    end

    refute Atoll.Repo.exists?(Atoll.Repositories.Head)
    assert Atoll.Repositories.Events.latest_seq() == 0
  end

  test "DID documents need no PDS fields, while full identities require valid ATProto fields",
       c do
    doc = %{"id" => @did, "alsoKnownAs" => []}
    Application.put_env(:atoll, :identity_resolution_options, options(doc))
    assert get(c.conn, @did_route, %{did: @did}) |> json_response(200) == %{"didDoc" => doc}
    assert get(c.conn, @identity_route, %{identifier: @did}) |> json_response(400)

    for doc <- [Map.put(c.doc, "alsoKnownAs", []), c.doc] do
      opts =
        Keyword.put(options(doc), :txt_lookup, fn _ -> [["did=did:web:other.example.com"]] end)

      Application.put_env(:atoll, :identity_resolution_options, opts)

      assert get(c.conn, @identity_route, %{identifier: @did})
             |> json_response(200)
             |> Map.fetch!("handle") == "handle.invalid"
    end
  end

  test "ordinary DID queries use the positive cache without forcing a network lookup", c do
    cache = start_supervised!({Cache, []})
    assert {:ok, _} = Cache.fetch(cache, @did, false, fn -> {:ok, c.doc} end)

    opts = [
      cache: cache,
      lookup: fn _ -> flunk("cached DID must not fetch") end,
      txt_lookup: fn _ -> [["did=" <> @did]] end
    ]

    Application.put_env(:atoll, :identity_resolution_options, opts)
    assert get(c.conn, @did_route, %{did: @did}) |> json_response(200) == %{"didDoc" => c.doc}

    assert get(c.conn, @identity_route, %{identifier: @did})
           |> json_response(200)
           |> Map.fetch!("handle") == @handle
  end

  test "missing identities, unsafe destinations and failed upstream responses return bounded errors",
       c do
    for {status, error} <- [
          {404, "DidNotFound"},
          {503, "InvalidRequest"},
          {302, "InvalidRequest"}
        ] do
      opts =
        Keyword.put(
          options(c.doc),
          :request,
          Req.new(plug: &Plug.Conn.send_resp(&1, status, "private upstream body"))
        )

      Application.put_env(:atoll, :identity_resolution_options, opts)

      for {route, params} <- [{@did_route, %{did: @did}}, {@identity_route, %{identifier: @did}}] do
        result = get(c.conn, route, params) |> json_response(400)
        assert result["error"] == error
        refute Jason.encode!(result) =~ "private upstream body"
      end
    end

    Application.put_env(:atoll, :identity_resolution_options,
      lookup: fn _ -> {:ok, {127, 0, 0, 1}} end,
      request: Req.new(plug: fn _ -> flunk("private address must not fetch") end),
      txt_lookup: fn _ -> [] end
    )

    assert get(c.conn, @did_route, %{did: @did}) |> json_response(400)

    assert get(c.conn, @identity_route, %{identifier: @handle})
           |> json_response(400)
           |> Map.fetch!("error") == "HandleNotFound"
  end

  test "validates query schemas, rejects request bodies, and shares a rate budget across identity queries",
       c do
    Application.put_env(:atoll, :identity_resolution_options,
      lookup: fn _ -> flunk("invalid queries must not fetch") end
    )

    for {route, key} <- [{@did_route, :did}, {@identity_route, :identifier}] do
      for params <- [%{}, %{key => "bad"}, %{key => [@did]}] do
        assert get(c.conn, route, params) |> json_response(400)
      end

      assert post(c.conn, route, %{}) |> json_response(405)

      assert c.conn
             |> put_req_header("content-type", "application/json")
             |> get(route, "{}")
             |> json_response(400)
    end

    for _ <- 1..60,
        do: Atoll.Accounts.SessionLimiter.check({:identity_resolution, c.conn.remote_ip}, 60)

    for route <- [@did_route, @identity_route, "/xrpc/com.atproto.identity.%72esolveHandle"] do
      result = get(c.conn, route)
      assert json_response(result, 429)["error"] == "RateLimitExceeded"
      assert get_resp_header(result, "retry-after") != []
    end
  end

  defp options(doc) do
    [
      request: Req.new(plug: fn conn -> Req.Test.json(conn, doc) end),
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      txt_lookup: fn _ -> [["did=" <> @did]] end
    ]
  end

  defp document(key) do
    {:ok, multikey} = Multikey.encode(key.curve, key.public)

    %{
      "id" => @did,
      "alsoKnownAs" => ["at://" <> @handle],
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
  end
end
