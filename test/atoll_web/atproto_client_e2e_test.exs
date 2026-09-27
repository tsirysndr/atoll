defmodule AtollWeb.AtprotoClientE2ETest do
  use Atoll.DataCase, async: false
  @moduletag :interop

  for curve <- [:k256, :p256] do
    @tag curve: curve
    test "official client writes and independently verifies the #{curve} repository", %{
      curve: curve
    } do
      api = System.fetch_env!("ATOLL_ATPROTO_API_PATH") |> Path.expand()
      repo = System.fetch_env!("ATOLL_ATPROTO_REPO_PATH") |> Path.expand()
      stream = System.fetch_env!("ATOLL_ATPROTO_XRPC_SERVER_PATH") |> Path.expand()

      keys = [
        :session_signing_key,
        :key_encryption_key,
        :blob_storage,
        :appview_proxy,
        :proxy_options
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

      Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))
      Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
      Application.put_env(:atoll, :blob_storage, backend: :postgres)
      server = start_supervised!({Bandit, plug: AtollWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
      {:ok, {_, port}} = ThousandIsland.listener_info(server)

      AtollWeb.Endpoint.config_change(
        [
          {AtollWeb.Endpoint,
           Keyword.put(endpoint, :url, scheme: "http", host: "127.0.0.1", port: port)}
        ],
        []
      )

      did = "did:plc:abcdefghijklmnopqrstuvwx"
      password = "disposable upstream test password"
      key = Atoll.SigningKey.generate(curve)
      {:ok, public} = Atoll.Multikey.to_did_key(key.curve, key.public)
      {:ok, genesis} = Atoll.Repositories.create(did, key)
      {:ok, :stored} = Atoll.KeyVault.store(did, key)
      {:ok, _} = Atoll.Accounts.Credentials.create(did, password)

      # A stubbed default AppView that indexed nothing past the genesis commit,
      # so timeline reads exercise read-after-write munging end to end.
      appview = "did:web:appview.example.com"
      Application.put_env(:atoll, :appview_proxy, appview <> "#bsky_appview")

      Application.put_env(:atoll, :proxy_options,
        resolver: [
          lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
          request:
            Req.new(
              plug: fn conn ->
                Req.Test.json(conn, %{
                  "id" => appview,
                  "service" => [
                    %{
                      "id" => "#bsky_appview",
                      "type" => "BskyAppView",
                      "serviceEndpoint" => "https://api.appview.example.com"
                    }
                  ]
                })
              end
            )
        ],
        lookup: fn "api.appview.example.com" -> {:ok, {1, 1, 1, 1}} end,
        request:
          Req.new(
            plug: fn conn ->
              {status, body} =
                if String.ends_with?(conn.request_path, "getPostThread"),
                  do: {400, %{"error" => "NotFound", "message" => "Post not found"}},
                  else: {200, %{"feed" => []}}

              conn
              |> Plug.Conn.put_resp_header("atproto-repo-rev", genesis.rev)
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(status, Jason.encode!(body))
            end
          )
      )

      {output, status} =
        System.cmd(
          "node",
          [
            "scripts/test_atproto_client.mjs",
            api,
            repo,
            AtollWeb.Endpoint.url(),
            did,
            password,
            public,
            stream,
            Integer.to_string(Atoll.Repositories.Events.latest_seq())
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "Official ATProto client and signed repository verification passed"
      assert Repo.aggregate(Atoll.Accounts.Session, :count) == 0
      assert Repo.aggregate(Atoll.Repositories.Record, :count) == 2
    end
  end
end
