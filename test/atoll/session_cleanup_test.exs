defmodule Atoll.SessionCleanupTest do
  use Atoll.DataCase, async: false
  alias Atoll.Moderation.AuditEntry
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

  test "audit entries retain only expiration policy and counts, including manual no-ops" do
    insert_session(1)
    assert {:ok, 1} = SessionCleanup.prune_expired(1)
    entry = Repo.one!(AuditEntry)
    assert entry.operation == "atoll.sessions.prune"
    assert entry.actor == "operator"
    assert entry.did == nil
    assert entry.subject == %{"kind" => "expiredSessions"}
    assert Map.keys(entry.requested) |> Enum.sort() == ["expiresAtOrBefore", "limit"]
    assert entry.requested["limit"] == 1
    assert entry.requested["expiresAtOrBefore"] <= System.system_time(:second)
    assert entry.before_state == %{}
    assert entry.after_state == %{"deleted" => 1}
    assert {:ok, 0} = SessionCleanup.prune_expired()
    [_, idle] = Repo.all(from a in AuditEntry, order_by: a.id)
    assert idle.after_state == %{"deleted" => 0}
  end

  test "audit failure restores deleted sessions" do
    row = insert_session(1)

    Repo.query!(
      "ALTER TABLE moderation_audit_entries ADD CONSTRAINT reject_session_audit CHECK (operation <> 'atoll.sessions.prune')"
    )

    assert_raise Ecto.ConstraintError, fn -> SessionCleanup.prune_expired() end
    assert Repo.get!(Session, row.id) == row
    assert Repo.aggregate(AuditEntry, :count) == 0
  end

  test "outer rollback also removes the audit and invalid attribution does no work" do
    row = insert_session(1)

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, 1} = SessionCleanup.prune_expired()
               assert Repo.aggregate(AuditEntry, :count) == 1
               Repo.rollback(:cancelled)
             end)

    assert {:error, :invalid_cleanup_actor} = SessionCleanup.prune_expired(1, "unknown")
    assert Repo.get!(Session, row.id) == row
    assert Repo.aggregate(AuditEntry, :count) == 0
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
