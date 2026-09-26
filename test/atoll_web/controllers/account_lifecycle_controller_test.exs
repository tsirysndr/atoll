defmodule AtollWeb.AccountLifecycleControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{KeyVault, Multikey, Repositories, SigningKey}
  alias Atoll.Accounts.{Credentials, Sessions}
  alias Atoll.Repositories.Events
  @did "did:web:lifecycle.example.com"
  @activate "/xrpc/com.atproto.server.activateAccount"
  @deactivate "/xrpc/com.atproto.server.deactivateAccount"

  setup %{conn: conn} do
    previous =
      Map.new(
        [:session_signing_key, :key_encryption_key, :identity_resolution_options],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "https", host: "pds.example.com", port: 443)}
      ],
      []
    )

    for key <- [:session_signing_key, :key_encryption_key],
        do: Application.put_env(:atoll, key, :binary.copy(<<27>>, 32))

    on_exit(fn ->
      AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], [])

      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, :stored} = KeyVault.store(@did, key)
    {:ok, _} = Credentials.create(@did, "account lifecycle password")
    {:ok, pair} = Sessions.create(@did, "account lifecycle password")
    {:ok, public} = Multikey.encode(key.curve, key.public)

    doc = %{
      "id" => @did,
      "verificationMethod" => [
        %{
          "id" => "#atproto",
          "controller" => @did,
          "type" => "Multikey",
          "publicKeyMultibase" => public
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

    configure(doc)
    id = rem(System.unique_integer([:positive]), 65_536)
    %{conn: %{conn | remote_ip: {10, 44, div(id, 256), rem(id, 256)}}, pair: pair, doc: doc}
  end

  test "deactivates and reactivates atomically with idempotent account events", c do
    seq = Events.latest_seq()
    assert response(deactivate(c, %{}), 200) == ""
    assert {:ok, %{status: :deactivated}} = Repositories.get_head(@did)
    assert {:error, {:repo_inactive, :deactivated}} = Repositories.export(@did)
    assert {:error, {:repo_inactive, :deactivated}} = Sessions.authenticate(c.pair.access_jwt)
    assert response(deactivate(c, %{deleteAfter: "2030-01-01T00:00:00Z"}), 200) == ""
    assert {:ok, [event]} = Events.list_after(seq)
    assert event.kind == :account
    assert response(activate(c), 200) == ""
    assert {:ok, %{did: @did}} = Sessions.authenticate(c.pair.access_jwt)
    assert response(activate(c), 200) == ""
    assert {:ok, events} = Events.list_after(seq)
    assert length(events) == 2
    assert Enum.all?(events, &(&1.kind == :account))
  end

  test "activation rejects mismatched DID service, unavailable keys and revocation during resolution",
       c do
    assert response(deactivate(c, %{}), 200) == ""
    seq = Events.latest_seq()

    configure(
      put_in(c.doc, ["service", Access.at(0), "serviceEndpoint"], "https://elsewhere.example.com")
    )

    assert activate(c) |> json_response(400)
    configure(c.doc)
    Application.delete_env(:atoll, :key_encryption_key)
    assert activate(c) |> json_response(503)
    Application.put_env(:atoll, :key_encryption_key, :binary.copy(<<27>>, 32))
    configure(c.doc, fn -> assert {:ok, :ok} = Sessions.revoke(c.pair.refresh_jwt) end)
    assert activate(c) |> json_response(401)
    assert {:ok, %{status: :deactivated}} = Repositories.get_head(@did)
    assert Events.latest_seq() == seq
  end

  test "validates deletion hints and requires a live access token", c do
    seq = Events.latest_seq()

    for hint <- [nil, "bad", "2030-01-01", 1] do
      assert deactivate(c, %{deleteAfter: hint}) |> json_response(400)
    end

    assert c.conn
           |> put_req_header("content-type", "application/json")
           |> post(@deactivate, %{})
           |> json_response(401)

    assert deactivate(%{c | pair: %{access_jwt: c.pair.refresh_jwt}}, %{}) |> json_response(401)
    assert Events.latest_seq() == seq

    for status <- [:takendown, :suspended] do
      {:ok, _} = Repositories.set_status(@did, status)
      assert deactivate(c, %{}) |> json_response(400)
      assert activate(c) |> json_response(400)
      assert {:ok, %{status: ^status}} = Repositories.get_head(@did)
    end
  end

  test "enforces POST, bounded JSON and shared rate limits", c do
    assert get(c.conn, @activate) |> response(405)

    assert c.conn
           |> bearer(c.pair.access_jwt)
           |> put_req_header("content-type", "application/json")
           |> post(@deactivate, String.duplicate("x", 4097))
           |> json_response(413)

    for _ <- 1..300, do: Atoll.Accounts.SessionLimiter.check({:session, c.conn.remote_ip}, 300)
    assert post(c.conn, "/xrpc/com.atproto.server.%61ctivateAccount") |> json_response(429)
  end

  defp activate(c), do: c.conn |> bearer(c.pair.access_jwt) |> post(@activate)

  defp deactivate(c, body),
    do:
      c.conn
      |> bearer(c.pair.access_jwt)
      |> put_req_header("content-type", "application/json")
      |> post(@deactivate, body)

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp configure(doc, callback \\ fn -> :ok end) do
    Application.put_env(:atoll, :identity_resolution_options,
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      request:
        Req.new(
          plug: fn conn ->
            callback.()
            Req.Test.json(conn, doc)
          end
        )
    )
  end
end
