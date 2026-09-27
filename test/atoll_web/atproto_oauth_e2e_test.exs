defmodule AtollWeb.AtprotoOAuthE2ETest do
  use Atoll.DataCase, async: false
  @moduletag :interop

  for {scenario, curve} <- [
        {"base", :k256},
        {"granular", :k256},
        {"blobs", :k256},
        {"email", :k256},
        {"rpc", :k256},
        {"rpc", :p256},
        {"confidential", :k256},
        {"key_removed", :k256},
        {"key_replaced", :k256}
      ] do
    @tag scenario: scenario, curve: curve
    test "official OAuth SDK verifies #{scenario} #{curve} grants through refresh and revocation",
         %{
           scenario: scenario,
           curve: curve
         } do
      package = System.fetch_env!("ATOLL_ATPROTO_OAUTH_CLIENT_PATH") |> Path.expand()

      keys = [
        :session_signing_key,
        :key_encryption_key,
        :oauth_nonce_secret,
        :localhost_dids_enabled,
        :blob_storage,
        :email_worker,
        :rate_limit_backend,
        :oauth_transport_options
      ]

      previous = Map.new(keys, &{&1, Application.fetch_env(:atoll, &1)})
      endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

      on_exit(fn ->
        AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], [])

        for {key, value} <- previous do
          case value do
            {:ok, value} -> Application.put_env(:atoll, key, value)
            :error -> Application.delete_env(:atoll, key)
          end
        end
      end)

      for key <- [:session_signing_key, :key_encryption_key, :oauth_nonce_secret],
          do: Application.put_env(:atoll, key, :crypto.strong_rand_bytes(32))

      Application.put_env(:atoll, :localhost_dids_enabled, true)
      Application.put_env(:atoll, :blob_storage, backend: :postgres)
      Application.put_env(:atoll, :email_worker, [])
      # Each loopback scenario gets real rate-limit rows rolled back with its sandbox.
      Application.put_env(:atoll, :rate_limit_backend, :postgres)
      server = start_supervised!({Bandit, plug: AtollWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
      {:ok, {_, port}} = ThousandIsland.listener_info(server)

      AtollWeb.Endpoint.config_change(
        [
          {AtollWeb.Endpoint,
           Keyword.put(endpoint, :url, scheme: "http", host: "localhost", port: port)}
        ],
        []
      )

      did = "did:plc:abcdefghijklmnopqrstuvwx"
      password = "disposable upstream OAuth password"
      {:ok, _} = Atoll.Repositories.create_managed(did, curve)
      {:ok, _} = Atoll.Accounts.Credentials.create(did, password)

      profile =
        Repo.insert!(%Atoll.Accounts.Profile{
          did: did,
          handle: "oauth-interop.example.com",
          email: "oauth-interop@example.com",
          email_confirmed_at: DateTime.utc_now()
        })

      {:ok, signing_key} = Atoll.KeyVault.fetch(did)
      Application.put_env(:atoll, :oauth_transport_options, [])
      parent = self()
      client_key = JOSE.JWK.generate_key({:ec, :secp256r1})
      {_, private_jwk} = JOSE.JWK.to_map(client_key)
      private_jwk = Map.merge(private_jwk, %{"kid" => "interop-client", "alg" => "ES256"})

      if scenario in ["confidential", "key_removed", "key_replaced"] do
        changed = scenario in ["key_removed", "key_replaced"]
        {_, replacement} = JOSE.JWK.to_public_map(JOSE.JWK.generate_key({:ec, :secp256r1}))

        replacement =
          Map.merge(replacement, %{
            "alg" => "ES256",
            "kid" =>
              if(scenario == "key_removed", do: "replacement-client", else: "interop-client")
          })

        metadata = %{
          "client_id" => "https://client.example.com/client.json",
          "redirect_uris" => ["https://client.example.com/callback"],
          "scope" => "atproto",
          "grant_types" => ["authorization_code", "refresh_token"],
          "response_types" => ["code"],
          "token_endpoint_auth_method" => "private_key_jwt",
          "token_endpoint_auth_signing_alg" => "ES256",
          "dpop_bound_access_tokens" => true,
          "jwks" => %{"keys" => [Map.delete(private_jwk, "d")]}
        }

        Application.put_env(:atoll, :oauth_transport_options,
          lookup: fn "client.example.com" -> {:ok, {8, 8, 8, 8}} end,
          request:
            Req.new(
              plug: fn conn ->
                assert conn.host == "8.8.8.8"
                assert Plug.Conn.get_req_header(conn, "host") == ["client.example.com"]
                assert conn.request_path == "/client.json"
                send(parent, :client_metadata_fetched)
                bindings = Repo.all(from s in Atoll.OAuth.Session, select: s.client_binding)
                send(parent, {:client_bindings, bindings})

                if changed and bindings != [] do
                  send(parent, :changed_client_key_advertised)
                  Req.Test.json(conn, put_in(metadata, ["jwks", "keys"], [replacement]))
                else
                  Req.Test.json(conn, metadata)
                end
              end
            )
        )
      end

      {output, status} =
        System.cmd(
          "node",
          [
            "scripts/test_atproto_oauth.mjs",
            package,
            AtollWeb.Endpoint.url(),
            did,
            password,
            scenario,
            Base.encode16(signing_key.public, case: :lower),
            Atom.to_string(curve)
          ],
          stderr_to_stdout: true,
          env: [{"ATOLL_TEST_CLIENT_JWK", Jason.encode!(private_jwk)}]
        )

      assert status == 0, output
      assert output =~ "Official ATProto OAuth client flow passed"

      if scenario in ["confidential", "key_removed", "key_replaced"] do
        minimum = if scenario == "confidential", do: 3, else: 2
        assert Repo.aggregate(Atoll.OAuth.ClientAssertionUse, :count) >= minimum
        if scenario != "confidential", do: assert_received(:changed_client_key_advertised)
        for _ <- 1..3, do: assert_received(:client_metadata_fetched)

        assert_received {:client_bindings,
                         [%{"kid" => "interop-client", "alg" => "ES256", "jkt" => thumbprint}]}

        assert thumbprint == JOSE.JWK.thumbprint(client_key)
      else
        assert Repo.aggregate(Atoll.OAuth.ClientAssertionUse, :count) == 0
      end

      assert Repo.aggregate(Atoll.OAuth.Session, :count) == 0
      expected_sources = if scenario in ["key_removed", "key_replaced"], do: 1, else: 0
      assert Repo.aggregate(Atoll.Accounts.Session, :count) == expected_sources
      assert Repo.aggregate(Atoll.OAuth.AccessToken, :count) == 0
      assert Repo.get!(Atoll.Accounts.Profile, did) == profile

      expected =
        if scenario == "granular",
          do: ["com.example.oauthrecord/first", "com.example.oauthrecord/second"],
          else: []

      assert Repo.all(from r in Atoll.Repositories.Record, order_by: r.path, select: r.path) ==
               expected

      expected_blobs =
        if scenario == "blobs",
          do:
            Enum.map(
              ["before refresh", "after refresh"],
              &Atoll.CID.create("allowed OAuth text " <> &1, :raw)
            )
            |> Enum.sort(),
          else: []

      assert Repo.all(from b in Atoll.Blobs.Blob, order_by: b.cid, select: b.cid) ==
               expected_blobs

      raw_prefix = <<1, 0x55, 0x12, 0x20>>

      assert Repo.all(
               from b in Atoll.Storage.Block,
                 where: fragment("substring(? from 1 for 4) = ?", b.cid, ^raw_prefix),
                 order_by: b.cid,
                 select: b.cid
             ) == expected_blobs

      for cid <- expected_blobs do
        assert {:ok, bytes} = Atoll.Storage.get_block(cid)
        assert bytes in ["allowed OAuth text before refresh", "allowed OAuth text after refresh"]
      end
    end
  end
end
