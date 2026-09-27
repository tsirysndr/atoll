defmodule AtollWeb.ServerControllerTest do
  use AtollWeb.ConnCase, async: false

  test "describes the configured server without authentication", %{conn: conn} do
    body = get(conn, ~p"/xrpc/com.atproto.server.describeServer") |> json_response(200)

    assert %{
             "did" => "did:web:pds.example.test",
             "availableUserDomains" => [".example.test"],
             "blobUploadLimit" => 5_242_880
           } = body

    refute Map.has_key?(body, "links")
    refute Map.has_key?(body, "contact")
  end

  test "tls-check approves the server host and completed handle hosts only", %{conn: conn} do
    host = URI.parse(AtollWeb.Endpoint.url()).host
    assert conn |> get("/tls-check", %{domain: host}) |> response(200) == ""
    assert conn |> get("/tls-check", %{domain: String.upcase(host)}) |> response(200) == ""
    assert conn |> get("/tls-check", %{domain: "alice.example.test"}) |> response(404)
    assert conn |> get("/tls-check") |> response(404)

    did = "did:web:tlscheck.example.test"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    Atoll.Repo.insert!(%Atoll.Accounts.Profile{did: did, handle: "alice.example.test"})
    response = get(conn, "/tls-check", %{domain: "alice.example.test"})
    assert response(response, 200) == ""
    assert get_resp_header(response, "cache-control") == ["no-store"]

    # Pending signups and unknown or foreign hosts get no certificate.
    prior = Application.fetch_env(:atoll, :key_encryption_key)
    Application.put_env(:atoll, :key_encryption_key, :binary.copy(<<41>>, 32))

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:atoll, :key_encryption_key, value)
        :error -> Application.delete_env(:atoll, :key_encryption_key)
      end
    end)

    key = Atoll.SigningKey.generate()
    rotation = Atoll.SigningKey.generate()
    {:ok, signing} = Atoll.Multikey.to_did_key(key.curve, key.public)
    {:ok, rotating} = Atoll.Multikey.to_did_key(rotation.curve, rotation.public)

    {:ok, genesis} =
      Atoll.Identity.PLC.Operation.create_atproto(
        signing,
        "pending.example.test",
        "https://pds.example.test",
        [rotating],
        rotation
      )

    {:ok, _} = Atoll.Repositories.create(genesis.did, key)
    {:ok, :stored} = Atoll.KeyVault.store(genesis.did, key)
    {:ok, _} = Atoll.Repositories.set_status(genesis.did, :deactivated)
    Atoll.Repo.insert!(%Atoll.Accounts.Profile{did: genesis.did, handle: "pending.example.test"})
    {:ok, _} = Atoll.Identity.PLC.Registrations.stage(genesis.did, genesis.operation, rotation)
    assert conn |> get("/tls-check", %{domain: "pending.example.test"}) |> response(404)
    assert conn |> get("/tls-check", %{domain: "missing.example.test"}) |> response(404)
    assert conn |> get("/tls-check", %{domain: "alice.elsewhere.test"}) |> response(404)
  end

  test "includes configured policy links and operator contact", %{conn: conn} do
    previous = Application.fetch_env!(:atoll, :pds)

    on_exit(fn -> Application.put_env(:atoll, :pds, previous) end)

    server =
      Atoll.ServerConfig.parse!(
        %{
          "ATOLL_PDS_DID" => "did:web:pds.example.test",
          "ATOLL_AVAILABLE_USER_DOMAINS" => ".example.test",
          "ATOLL_PRIVACY_POLICY_URL" => "https://pds.example.test/privacy",
          "ATOLL_TERMS_OF_SERVICE_URL" => "https://pds.example.test/terms",
          "ATOLL_CONTACT_EMAIL" => "Admin@Example.test"
        },
        false
      )

    Application.put_env(:atoll, :pds, server.pds)
    body = get(conn, ~p"/xrpc/com.atproto.server.describeServer") |> json_response(200)

    assert body["links"] == %{
             "privacyPolicy" => "https://pds.example.test/privacy",
             "termsOfService" => "https://pds.example.test/terms"
           }

    assert body["contact"] == %{"email" => "admin@example.test"}

    for {name, value} <- [
          {"ATOLL_PRIVACY_POLICY_URL", "http://insecure.example.test"},
          {"ATOLL_TERMS_OF_SERVICE_URL", "not a url"},
          {"ATOLL_CONTACT_EMAIL", "not-an-address"}
        ] do
      assert_raise RuntimeError, ~r/#{name}/, fn ->
        Atoll.ServerConfig.parse!(%{name => value}, false)
      end
    end
  end
end
