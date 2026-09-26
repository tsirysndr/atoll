defmodule Atoll.SessionCleanupTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{Credentials, Session, SessionCleanup, Sessions, Tokens}
  @did "did:plc:sessioncleanup"

  setup do
    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    :ok
  end

  test "deletes oldest expired sessions in bounded, repeatable batches" do
    oldest = insert_session(1)
    middle = insert_session(2)
    newest = insert_session(3)
    live = insert_session(System.system_time(:second) + 3600)
    assert {:ok, 2} = SessionCleanup.prune_expired(2)
    refute Repo.get(Session, oldest.id)
    refute Repo.get(Session, middle.id)
    assert Repo.get(Session, newest.id)
    assert Repo.get(Session, live.id)
    assert {:ok, 1} = SessionCleanup.prune_expired(2)
    assert {:ok, 0} = SessionCleanup.prune_expired()
    assert Repo.get(Session, live.id)
  end

  test "rejects invalid limits without deleting anything" do
    session = insert_session(1)

    for limit <- [0, -1, 1001, "10", nil, 1.5] do
      assert {:error, :invalid_limit} = SessionCleanup.prune_expired(limit)
    end

    assert Repo.get(Session, session.id)
  end

  test "retains a working login and rotated refresh token" do
    opts = [secret: :binary.copy(<<25>>, 32), audience: "did:web:pds.example.com"]
    {:ok, _} = Credentials.create(@did, "cleanup test password")
    {:ok, pair} = Sessions.create(@did, "cleanup test password", opts)
    {:ok, rotated} = Sessions.refresh(pair.refresh_jwt, opts)
    insert_session(1)
    assert {:ok, 1} = SessionCleanup.prune_expired()
    assert {:ok, %{did: @did}} = Sessions.authenticate(pair.access_jwt, opts)
    assert {:ok, _} = Sessions.refresh(rotated.refresh_jwt, opts)
  end

  test "operator task validates arguments and reports only the batch count" do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    insert_session(1)
    insert_session(2)

    for args <- [
          ["--limit", "0"],
          ["--limit", "1001"],
          ["--limit", "bad"],
          ["--all"],
          ["extra"],
          ["--limit", "1", "--limit", "2"]
        ] do
      assert_raise Mix.Error, fn -> Mix.Tasks.Atoll.Sessions.Prune.run(args) end
    end

    assert Repo.aggregate(Session, :count) == 2
    Mix.Tasks.Atoll.Sessions.Prune.run(["--limit", "1"])
    assert_receive {:mix_shell, :info, ["Deleted 1 expired sessions (batch limit 1)."]}
    assert Repo.aggregate(Session, :count) == 1
  end

  defp insert_session(expiry) do
    Repo.insert!(%Session{
      id: Tokens.random_id(),
      did: @did,
      refresh_hash: :crypto.strong_rand_bytes(32),
      expires_at: expiry
    })
  end
end
