defmodule Atoll.BlobCollectionAuditTest do
  # These tests temporarily alter the shared audit table's constraints.
  use Atoll.DataCase, async: false
  alias Atoll.{CID, Storage}
  alias Atoll.Blobs.{Cleanup, CleanupJob}
  alias Atoll.Moderation.AuditEntry

  test "operator command records intent, per-item deletion and completed counts" do
    cid = queued("private queued content")

    output =
      ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Atoll.Blobs.Collect.run(["--limit", "1"]) end)

    assert Jason.decode!(String.trim(output)) == %{
             "deleted" => 1,
             "retained" => 0,
             "failed" => 0,
             "skipped" => 0
           }

    [attempt, item, completed] = history()
    assert attempt.after_state == %{"phase" => "attempt"}

    assert attempt.requested == %{
             "limit" => 1,
             "jobs" => [%{"cid" => CID.to_base32(cid), "backend" => "postgres"}]
           }

    assert item.subject == %{
             "kind" => "blobCollection",
             "cid" => CID.to_base32(cid),
             "backend" => "postgres"
           }

    assert item.after_state == %{"phase" => "item", "outcome" => "deleted"}
    assert completed.after_state["counts"]["deleted"] == 1
    assert completed.after_state["phase"] == "completed"

    for row <- [item, completed],
        do: assert(row.requested == %{"attemptId" => Integer.to_string(attempt.id)})

    for row <- [attempt, item, completed] do
      assert row.did == nil and row.actor == "operator"
      refute Jason.encode!([row.requested, row.after_state]) =~ "private queued content"
    end

    assert Storage.get_block(cid) == {:error, :not_found}
    assert Repo.aggregate(CleanupJob, :count) == 0
  end

  test "attempt failure prevents deletion and item failure rolls back PostgreSQL deletion" do
    cid = queued("retained bytes")
    reject_phase("attempt")
    assert_raise Ecto.ConstraintError, fn -> Cleanup.collect() end
    assert history() == []
    assert {:ok, "retained bytes"} = Storage.get_block(cid)
    assert Repo.get_by!(CleanupJob, cid: cid)
    Repo.query!("ALTER TABLE moderation_audit_entries DROP CONSTRAINT reject_collection_phase")

    reject_phase("item")
    assert_raise Ecto.ConstraintError, fn -> Cleanup.collect() end
    assert {:ok, "retained bytes"} = Storage.get_block(cid)
    assert Repo.get_by!(CleanupJob, cid: cid)
    [attempt] = history()
    assert attempt.after_state == %{"phase" => "attempt"}
  end

  test "S3 deletion before item audit failure leaves intent and retryable queue state" do
    cid = queued("remote object", :s3)
    reject_phase("item")
    parent = self()

    opts =
      s3(fn conn ->
        assert conn.method == "DELETE"
        assert Repo.in_transaction?()
        [attempt] = history()
        assert attempt.after_state["phase"] == "attempt"
        send(parent, :remote_deleted)
        Plug.Conn.send_resp(conn, 204, "")
      end)

    assert_raise Ecto.ConstraintError, fn -> Cleanup.collect(opts) end
    assert_received :remote_deleted
    assert Repo.get_by!(CleanupJob, cid: cid, backend: :s3)
    assert length(history()) == 1
    Repo.query!("ALTER TABLE moderation_audit_entries DROP CONSTRAINT reject_collection_phase")
    assert {:ok, %{deleted: 1}} = Cleanup.collect(s3(&Plug.Conn.send_resp(&1, 204, "")))
    assert Repo.aggregate(CleanupJob, :count) == 0
    assert length(history()) == 4
  end

  test "failed S3 requests retain jobs with sanitized worker outcomes" do
    cid = queued("failed remote object", :s3)
    opts = s3(&Plug.Conn.send_resp(&1, 503, "private upstream failure")) ++ [actor: "worker"]
    assert {:ok, %{failed: 1, deleted: 0}} = Cleanup.collect(opts)
    assert Repo.get_by!(CleanupJob, cid: cid, backend: :s3)
    [_, item, completed] = history()
    assert item.after_state == %{"phase" => "item", "outcome" => "failed"}
    assert completed.after_state["counts"]["failed"] == 1

    for row <- history() do
      assert row.actor == "worker"
      refute Jason.encode!([row.requested, row.after_state]) =~ "private upstream failure"
    end
  end

  test "empty worker runs are quiet and operator no-ops have completed history" do
    assert {:ok, %{deleted: 0}} = Cleanup.collect(actor: "worker")
    assert history() == []
    assert {:ok, %{deleted: 0}} = Cleanup.collect()
    assert Enum.map(history(), & &1.after_state["phase"]) == ["attempt", "completed"]
  end

  test "later item failure preserves earlier commits and leaves an incomplete batch" do
    first = queued("first deletion")
    second = queued("second deletion")

    Repo.query!(
      "ALTER TABLE moderation_audit_entries ADD CONSTRAINT reject_second_collection CHECK (operation <> 'atoll.blobs.collect' OR after_state->>'phase' <> 'item' OR subject->>'cid' <> '#{CID.to_base32(second)}')"
    )

    assert_raise Mix.Error, ~r/earlier items or remote deletions may have completed/, fn ->
      Mix.Tasks.Atoll.Blobs.Collect.run([])
    end

    assert Storage.get_block(first) == {:error, :not_found}
    assert {:ok, "second deletion"} = Storage.get_block(second)
    assert Repo.get_by!(CleanupJob, cid: second)
    refute Repo.get_by(CleanupJob, cid: first)
    [attempt, item] = history()
    assert attempt.after_state["phase"] == "attempt"
    assert item.subject["cid"] == CID.to_base32(first)
    assert item.after_state == %{"phase" => "item", "outcome" => "deleted"}
  end

  test "invalid actors and command arguments do not touch queued bytes" do
    cid = queued("protected")
    assert Cleanup.collect(actor: "untrusted") == {:error, :invalid_cleanup_options}

    for args <- [
          ["--limit", "0"],
          ["--limit", "1001"],
          ["--limit", "1", "--limit", "2"],
          ["extra"],
          ["--actor", "worker"]
        ] do
      assert_raise Mix.Error, fn -> Mix.Tasks.Atoll.Blobs.Collect.run(args) end
    end

    assert history() == []
    assert {:ok, "protected"} = Storage.get_block(cid)
  end

  defp queued(bytes, backend \\ :postgres) do
    cid = CID.create(bytes, :raw)
    if backend == :postgres, do: :ok = Storage.put_block(cid, bytes)
    Repo.insert!(%CleanupJob{cid: cid, backend: backend, queued_at: DateTime.utc_now()})
    cid
  end

  defp history,
    do:
      Repo.all(from a in AuditEntry, where: a.operation == "atoll.blobs.collect", order_by: a.id)

  defp reject_phase(phase) when phase in ["attempt", "item"] do
    Repo.query!(
      "ALTER TABLE moderation_audit_entries ADD CONSTRAINT reject_collection_phase CHECK (operation <> 'atoll.blobs.collect' OR after_state->>'phase' <> '#{phase}')"
    )
  end

  defp s3(plug) do
    [
      storage: [
        backend: :s3,
        s3: [
          endpoint: "https://storage.example.com",
          bucket: "test-bucket",
          access_key_id: "test",
          secret_access_key: "test",
          request: Req.new(plug: plug)
        ]
      ]
    ]
  end
end
