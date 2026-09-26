defmodule Atoll.AuthenticatorConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Accounts.{Authenticator, Credentials, Sessions, TOTP, TOTPFactor}
  alias Ecto.Adapters.SQL.Sandbox

  for kind <- [:totp, :recovery] do
    @kind kind
    test "independent database connections admit the same #{@kind} code at most once" do
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

      did = "did:plc:totprace#{System.unique_integer([:positive])}"

      {digest, code, created_blocks} =
        Sandbox.unboxed_run(Repo, fn ->
          prior_blocks = Repo.all(from b in Atoll.Storage.Block, select: b.cid)
          {:ok, _head} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
          created_blocks = Repo.all(from b in Atoll.Storage.Block, select: b.cid) -- prior_blocks
          {:ok, _} = Credentials.create(did, "concurrent factor password")
          {:ok, pair} = Sessions.create(did, "concurrent factor password")
          {:ok, enrollment} = Authenticator.begin(pair.access_jwt, "concurrent factor password")
          secret = Base.decode32!(enrollment.secret, padding: false)
          now = System.system_time(:second)
          {:ok, initial} = TOTP.code(secret, now)
          {:ok, %{recovery_codes: recovery}} = Authenticator.confirm(pair.access_jwt, initial)
          {:ok, code} = TOTP.code(secret, now + 30)
          code = if @kind == :recovery, do: hd(recovery), else: code
          {:ok, digest} = Credentials.verified_digest(did, "concurrent factor password")
          {digest, code, created_blocks}
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from e in Atoll.Repositories.Event, where: e.did == ^did)
          Repo.delete_all(from h in Atoll.Repositories.Head, where: h.did == ^did)
          Repo.delete_all(from b in Atoll.Storage.Block, where: b.cid in ^created_blocks)
        end)
      end)

      supervisor = start_supervised!(Task.Supervisor)
      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.Supervisor.async_nolink(supervisor, fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> :ok
            end

            Sandbox.unboxed_run(Repo, fn -> Authenticator.check_login(did, digest, code) end)
          end)
        end

      for _ <- tasks, do: assert_receive({:ready, _})
      for task <- tasks, do: send(task.pid, :go)
      results = Enum.map(tasks, &Task.await(&1, 10_000))
      assert Enum.count(results, &match?({:ok, %{step: _}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :invalid_totp})) == 1

      Sandbox.unboxed_run(Repo, fn ->
        # Confirmation, successful login admission, then failed replay all committed.
        assert Repo.get!(TOTPFactor, did).attempts == 3
      end)
    end
  end
end
