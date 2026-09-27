defmodule Atoll.Repositories.CompactionTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Repositories, SigningKey}
  alias Atoll.Moderation.AuditEntry

  alias Atoll.Repositories.{
    Compaction,
    Event,
    EventDependency,
    EventEncoder,
    EventRetention,
    Revision,
    Quota
  }

  @did "did:plc:compaction"

  test "replay pins current and predecessor revisions until their events expire" do
    [first, second, current] = history()
    before = Quota.usage(@did)
    assert {:ok, snapshot} = Repositories.export(@did)
    assert {:ok, %{pruned: 0}} = Compaction.prune(@did, 100, 3600)
    latest = Repo.one!(from e in Event, order_by: [desc: e.seq], limit: 1)
    {:ok, payload} = Atoll.CBOR.decode(latest.payload)
    decoded = %{latest | payload: payload}
    assert {:ok, frame} = EventEncoder.encode(decoded)
    old_events(from e in Event, where: e.seq < ^latest.seq)
    assert {:ok, %{deleted: 2}} = EventRetention.prune(1000, 3600)
    assert {:ok, %{pruned: 1}} = Compaction.prune(@did, 100, 3600)
    refute Repo.get_by(Revision, did: @did, rev: first.rev)
    assert Repo.get_by(Revision, did: @did, rev: second.rev)
    assert {:ok, ^frame} = EventEncoder.encode(decoded)
    old_events(Event)
    assert {:ok, %{deleted: 1}} = EventRetention.prune(1000, 3600)
    assert {:ok, %{pruned: 1}} = Compaction.prune(@did, 100, 3600)
    assert Repo.all(Revision) == [current]
    assert Quota.usage(@did).count < before.count
    assert {:ok, ^snapshot} = Repositories.export(@did)
    assert {:ok, ^snapshot} = Repositories.export(@did, first.rev)
  end

  test "missing legacy event dependencies are backfilled before removing any revision" do
    history()
    Repo.delete_all(EventDependency)
    assert {:ok, %{indexed: 3, incomplete: false, pruned: 0}} = Compaction.prune(@did, 100, 3600)
    assert Repo.aggregate(EventDependency, :count) == 5
    assert {:ok, %{indexed: 0, pruned: 0}} = Compaction.prune(@did, 100, 3600)
  end

  test "large legacy event backfills defer all compaction until indexing completes" do
    history()
    event = Repo.one!(from e in Event, order_by: [desc: e.seq], limit: 1)
    attrs = Map.take(event, [:did, :kind, :payload, :time])
    Repo.insert_all(Event, List.duplicate(attrs, 1001))

    assert {:ok, %{indexed: 1000, incomplete: true, pruned: 0}} =
             Compaction.prune(@did, 100, 3600)

    assert {:ok, %{indexed: 1, incomplete: false, pruned: 0}} = Compaction.prune(@did, 100, 3600)
  end

  test "bounded removal rolls back with its reference counts and respects age" do
    revisions = history()
    Repo.delete_all(Event)
    before = Quota.usage(@did)

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, %{pruned: 1}} = Compaction.prune(@did, 1, 3600)
               Repo.rollback(:cancelled)
             end)

    assert Repo.all(from r in Revision, order_by: r.rev) == revisions
    assert Quota.usage(@did) == before
    assert {:ok, %{pruned: 0}} = Compaction.prune(@did, 100, 604_800)
    assert {:ok, %{pruned: 1}} = Compaction.prune(@did, 1, 3600)
  end

  test "audits removed revisions and the preserved head with bounded operator inputs" do
    [first, _, current] = history()
    Repo.delete_all(Event)
    assert {:ok, result} = Compaction.prune(@did, 1, 3600)
    entry = Repo.one!(AuditEntry)
    assert entry.operation == "atoll.revisions.prune"
    assert entry.actor == "operator"
    assert entry.did == @did
    assert entry.subject == %{"kind" => "repositoryHistory", "did" => @did}
    assert entry.requested == %{"limit" => 1, "retentionSeconds" => 3600}

    assert entry.before_state == %{
             "head" => Atoll.CID.to_base32(current.head),
             "rev" => current.rev,
             "removedRevisions" => [first.rev]
           }

    assert entry.after_state ==
             Map.merge(Jason.decode!(Jason.encode!(result)), %{
               "head" => Atoll.CID.to_base32(current.head),
               "rev" => current.rev
             })
  end

  test "dependency-only batches are audited and audit rows roll back with maintenance" do
    history()
    Repo.delete_all(EventDependency)

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, %{indexed: 3, pruned: 0}} = Compaction.prune(@did)
               assert Repo.one!(AuditEntry).after_state["indexed"] == 3
               Repo.rollback(:cancelled)
             end)

    assert Repo.aggregate(EventDependency, :count) == 0
    assert Repo.aggregate(AuditEntry, :count) == 0
    assert {:ok, %{indexed: 3, pruned: 0}} = Compaction.prune(@did)
    assert Repo.one!(AuditEntry).before_state["removedRevisions"] == []
  end

  test "audit insertion failure rolls back deleted revisions" do
    revisions = history()
    Repo.delete_all(Event)
    usage = Quota.usage(@did)

    Repo.query!(
      "ALTER TABLE moderation_audit_entries ADD CONSTRAINT reject_pruning_audit CHECK (operation <> 'atoll.revisions.prune')"
    )

    assert_raise Ecto.ConstraintError, fn -> Compaction.prune(@did, 1, 3600) end

    assert Repo.all(from r in Revision, order_by: r.rev) == revisions
    assert Quota.usage(@did) == usage
    assert Repo.aggregate(AuditEntry, :count) == 0
  end

  test "operator command reports results and rejects invalid or duplicate options" do
    history()

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Revisions.Prune.run([@did, "--retention-seconds", "3600"])
      end)

    assert Jason.decode!(output) == %{"indexed" => 0, "incomplete" => false, "pruned" => 0}

    for args <- [[], [@did, "--limit", "101"], [@did, "--limit", "1", "--limit", "2"]] do
      assert_raise Mix.Error, fn -> Mix.Tasks.Atoll.Revisions.Prune.run(args) end
    end

    assert {:error, :not_found} = Compaction.prune("did:plc:missing")
    assert {:error, :invalid_compaction_options} = Compaction.prune(@did, 0)
    assert Repo.aggregate(AuditEntry, :count) == 1
  end

  defp history do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)

    for text <- ["first", "second"] do
      {:ok, _} =
        Repositories.apply_writes(
          @did,
          [{:put, "com.example.record/one", %{"$type" => "com.example.record", "text" => text}}],
          key
        )
    end

    Repo.update_all(Revision,
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -7200, :second)]
    )

    Repo.all(from r in Revision, order_by: r.rev)
  end

  defp old_events(query) do
    Repo.update_all(query, set: [time: DateTime.add(DateTime.utc_now(), -7200, :second)])
  end
end
