defmodule AtollWeb.PasskeyBrowserE2ETest do
  use Atoll.DataCase, async: false
  @moduletag :browser

  test "Chrome enrolls, signs in, removes its key and recovers with the password" do
    previous =
      Map.new(
        [:session_signing_key, :key_encryption_key, :passkeys_enabled],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :passkeys_enabled, true)
    server = start_supervised!({Bandit, plug: AtollWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "http", host: "localhost", port: port)}
      ],
      []
    )

    on_exit(fn ->
      AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], [])

      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    did = "did:plc:virtualpasskeybrowser"
    password = "synthetic browser password"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    {:ok, _} = Atoll.Accounts.Credentials.create(did, password)

    {output, code} =
      System.cmd(
        "node",
        ["scripts/test_passkeys_browser.mjs", AtollWeb.Endpoint.url(), did, password],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "Passkey browser flow passed"
    assert Repo.aggregate(Atoll.Accounts.Passkey, :count) == 0
    assert Repo.aggregate(Atoll.Accounts.PasskeyChallenge, :count) == 0
    # Recovery signed in with the password after the passkey session was revoked.
    assert Repo.aggregate(Atoll.Accounts.Session, :count) == 1
  end
end
