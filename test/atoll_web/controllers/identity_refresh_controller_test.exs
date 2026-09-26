defmodule AtollWeb.IdentityRefreshControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Multikey, Repositories, SigningKey, Repo}
  alias Atoll.Accounts.{AppPasswords, Credentials, Sessions}
  alias Atoll.Identity.{Observation, Updates}
  alias Atoll.Repositories.Events
  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  @handle "alice.example.com"
  @path "/xrpc/com.atproto.identity.refreshIdentity"

  setup %{conn: conn} do
    prior =
      Map.new(
        [:session_signing_key, :identity_resolution_options],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, _} = Credentials.create(@did, "identity refresh password")
    {:ok, pair} = Sessions.create(@did, "identity refresh password")
    doc = document(key)
    Application.put_env(:atoll, :identity_resolution_options, options(doc))
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 67, div(id, 256), rem(id, 256)}}, pair: pair, doc: doc}
  end

  test "fresh DID and handle requests return full identity and only publish changed observations",
       c do
    seq = Events.latest_seq()

    assert request(c, @did) |> json_response(200) == %{
             "did" => @did,
             "handle" => @handle,
             "didDoc" => c.doc
           }

    assert request(c, String.upcase(@handle)) |> json_response(200) == %{
             "did" => @did,
             "handle" => @handle,
             "didDoc" => c.doc
           }

    assert {:ok, [event]} = Events.list_after(seq)
    assert event.kind == :identity
    assert event.payload == %{"handle" => @handle}
    result = request(c, @did)
    assert get_resp_header(result, "cache-control") == ["no-store"]

    opts =
      Keyword.put(options(c.doc), :txt_lookup, fn _ -> [["did=did:web:other.example.com"]] end)

    Application.put_env(:atoll, :identity_resolution_options, opts)
    assert request(c, @did) |> json_response(200) |> Map.fetch!("handle") == "handle.invalid"
  end

  test "deactivated owners bypass a stale cache and receive the newly resolved document", c do
    cache = start_supervised!({Atoll.Identity.Cache, []})
    old = Map.put(c.doc, "version", "old")
    assert {:ok, ^old} = Atoll.Identity.Cache.fetch(cache, @did, false, fn -> {:ok, old} end)
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    fresh = Map.put(c.doc, "version", "fresh")

    Application.put_env(
      :atoll,
      :identity_resolution_options,
      Keyword.put(options(fresh), :cache, cache)
    )

    assert request(c, @did) |> json_response(200) |> Map.fetch!("didDoc") == fresh

    assert {:ok, ^fresh} =
             Atoll.Identity.Cache.fetch(cache, @did, false, fn ->
               flunk("expected refreshed cache")
             end)

    assert {:ok, %{status: :deactivated}} = Repositories.get_head(@did)
  end

  test "requires full owner authorization before network access", c do
    Application.put_env(:atoll, :identity_resolution_options,
      lookup: fn _ -> flunk("unauthorized network request") end
    )

    assert c.conn
           |> put_req_header("content-type", "application/json")
           |> post(@path, %{identifier: @did})
           |> json_response(401)

    assert request(c, "did:web:other.example.com") |> json_response(403)
    {:ok, app} = AppPasswords.create(c.pair.access_jwt, %{"name" => "refresh app"})
    {:ok, pair} = Sessions.create(@did, app.password)
    assert request(%{c | pair: pair}, @did) |> json_response(403)
    {:ok, _} = Repositories.set_status(@did, :takendown)
    assert request(c, @did) |> json_response(400)
    assert Repo.get(Observation, @did) == nil
  end

  test "session revoked during resolution cannot publish an observation", c do
    opts =
      Keyword.put(
        options(c.doc),
        :request,
        Req.new(
          plug: fn conn ->
            assert {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt)
            Req.Test.json(conn, c.doc)
          end
        )
      )

    seq = Events.latest_seq()

    assert {:error, :invalid_token} =
             Updates.refresh_authenticated(c.pair.access_jwt, %{"identifier" => @did}, opts)

    assert Repo.get(Observation, @did) == nil
    assert Events.latest_seq() == seq
  end

  test "failed resolution preserves observations and maps missing DID separately", c do
    assert request(c, @did) |> json_response(200)
    before = Repo.get!(Observation, @did)
    seq = Events.latest_seq()

    for {status, error} <- [{404, "DidNotFound"}, {503, "InvalidRequest"}] do
      opts =
        Keyword.put(
          options(c.doc),
          :request,
          Req.new(plug: &Plug.Conn.send_resp(&1, status, "unavailable"))
        )

      Application.put_env(:atoll, :identity_resolution_options, opts)
      assert request(c, @did) |> json_response(400) |> Map.fetch!("error") == error
    end

    assert Repo.get!(Observation, @did) == before
    assert Events.latest_seq() == seq
  end

  test "bounds JSON and applies the existing strict request budget", c do
    conn =
      c.conn
      |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
      |> put_req_header("content-type", "application/json")

    assert post(conn, @path, String.duplicate(" ", 4097)) |> json_response(413)
    assert post(conn, @path, %{identifier: @did, extra: true}) |> json_response(400)
    assert get(conn, @path) |> json_response(405)
    for _ <- 1..20, do: Atoll.Accounts.SessionLimiter.check({:login, c.conn.remote_ip}, 20)
    assert request(c, @did) |> json_response(429)
  end

  defp request(c, identifier),
    do:
      c.conn
      |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
      |> put_req_header("content-type", "application/json")
      |> post(@path, %{identifier: identifier})

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
