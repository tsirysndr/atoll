defmodule Atoll.PasskeyConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Accounts.{Credentials, Sessions, Passkeys, Passkey, PasskeyChallenge}
  alias Atoll.PasskeyFixtures, as: Fixture
  alias Ecto.Adapters.SQL.Sandbox

  for ceremony <- [:register, :login] do
    @ceremony ceremony
    test "independent connections consume a #{@ceremony} challenge exactly once" do
      for name <- [:session_signing_key, :key_encryption_key] do
        prior = Application.fetch_env(:atoll, name)
        Application.put_env(:atoll, name, :crypto.strong_rand_bytes(32))

        on_exit(fn ->
          case prior do
            {:ok, value} -> Application.put_env(:atoll, name, value)
            :error -> Application.delete_env(:atoll, name)
          end
        end)
      end

      did = "did:plc:passkeyrace#{System.unique_integer([:positive])}"
      browser = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      {pair, request, response, created_blocks} =
        Sandbox.unboxed_run(Repo, fn ->
          prior = Repo.all(from b in Atoll.Storage.Block, select: b.cid)
          {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
          blocks = Repo.all(from b in Atoll.Storage.Block, select: b.cid) -- prior
          {:ok, _} = Credentials.create(did, "concurrent passkey password")
          {:ok, pair} = Sessions.create(did, "concurrent passkey password")

          {:ok, request} =
            Passkeys.begin_registration(
              pair.access_jwt,
              "concurrent passkey password",
              browser,
              "Key"
            )

          fixture = Fixture.new(request.public_key)
          response = Fixture.registration(fixture)

          if @ceremony == :login do
            {:ok, _} =
              Passkeys.complete_registration(
                pair.access_jwt,
                browser,
                request.reference,
                response
              )

            {:ok, request} = Passkeys.begin_login(browser)
            # Zero-counter credentials rely on challenge consumption for replay protection.
            response =
              Fixture.assertion(%{fixture | context: Fixture.context(request.public_key)},
                count: 0
              )

            {pair, request, response, blocks}
          else
            {pair, request, response, blocks}
          end
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from e in Atoll.Repositories.Event, where: e.did == ^did)
          Repo.delete_all(from h in Atoll.Repositories.Head, where: h.did == ^did)

          Repo.delete_all(
            from c in PasskeyChallenge,
              where: c.digest == ^:crypto.hash(:sha256, request.reference)
          )

          Repo.delete_all(from b in Atoll.Storage.Block, where: b.cid in ^created_blocks)
        end)
      end)

      supervisor = start_supervised!(Task.Supervisor)
      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.Supervisor.async_nolink(supervisor, fn ->
            send(parent, {:ready, self()})
            receive do: (:go -> :ok)

            Sandbox.unboxed_run(Repo, fn ->
              if @ceremony == :login,
                do: Passkeys.complete_login(browser, request.reference, response),
                else:
                  Passkeys.complete_registration(
                    pair.access_jwt,
                    browser,
                    request.reference,
                    response
                  )
            end)
          end)
        end

      for _ <- tasks, do: assert_receive({:ready, _})
      for task <- tasks, do: send(task.pid, :go)
      results = Enum.map(tasks, &Task.await(&1, 10_000))
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :invalid_passkey})) == 1

      Sandbox.unboxed_run(Repo, fn ->
        assert Repo.aggregate(from(k in Passkey, where: k.did == ^did), :count) == 1
        assert Repo.get_by!(Passkey, did: did).sign_count == 0
      end)
    end
  end
end
