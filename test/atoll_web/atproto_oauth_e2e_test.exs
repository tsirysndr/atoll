defmodule AtollWeb.AtprotoOAuthE2ETest do
  use Atoll.DataCase, async: false
  @moduletag :interop

  test "official OAuth SDK discovers, authorizes, refreshes and observes revocation" do
    package = System.fetch_env!("ATOLL_ATPROTO_OAUTH_CLIENT_PATH") |> Path.expand()

    keys = [
      :session_signing_key,
      :key_encryption_key,
      :oauth_nonce_secret,
      :localhost_dids_enabled
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

    {output, status} =
      System.cmd(
        "node",
        ["scripts/test_atproto_oauth.mjs", package, AtollWeb.Endpoint.url(), did, password],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "Official ATProto OAuth client flow passed"
    assert Repo.aggregate(Atoll.OAuth.Session, :count) == 0
    assert Repo.aggregate(Atoll.Accounts.Session, :count) == 0
  end
end
