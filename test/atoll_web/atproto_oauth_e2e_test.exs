defmodule AtollWeb.AtprotoOAuthE2ETest do
  use Atoll.DataCase, async: false
  @moduletag :interop

  for scenario <- ["base", "granular", "blobs", "email"] do
    @tag scenario: scenario
    test "official OAuth SDK verifies #{scenario} grants through refresh and revocation", %{
      scenario: scenario
    } do
      package = System.fetch_env!("ATOLL_ATPROTO_OAUTH_CLIENT_PATH") |> Path.expand()

      keys = [
        :session_signing_key,
        :key_encryption_key,
        :oauth_nonce_secret,
        :localhost_dids_enabled,
        :blob_storage,
        :email_worker
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
      {:ok, _} = Atoll.Repositories.create_managed(did)
      {:ok, _} = Atoll.Accounts.Credentials.create(did, password)

      profile =
        Repo.insert!(%Atoll.Accounts.Profile{
          did: did,
          handle: "oauth-interop.example.com",
          email: "oauth-interop@example.com",
          email_confirmed_at: DateTime.utc_now()
        })

      {output, status} =
        System.cmd(
          "node",
          [
            "scripts/test_atproto_oauth.mjs",
            package,
            AtollWeb.Endpoint.url(),
            did,
            password,
            scenario
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "Official ATProto OAuth client flow passed"
      assert Repo.aggregate(Atoll.OAuth.Session, :count) == 0
      assert Repo.aggregate(Atoll.Accounts.Session, :count) == 0
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
