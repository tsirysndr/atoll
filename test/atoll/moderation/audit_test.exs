defmodule Atoll.Moderation.AuditTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Blobs, CID, Repositories, SigningKey}
  alias Atoll.Accounts.SubjectStatus
  alias Atoll.Moderation.{Audit, AuditEntry}
  alias Atoll.Repositories.Events
  @did "did:web:audit.example.com"
  @account %{"$type" => "com.atproto.admin.defs#repoRef", "did" => @did}

  setup do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    %{key: key}
  end

  test "account decisions retain requested and actual states, including no-ops and private reason changes" do
    request = %{
      "subject" => @account,
      "takedown" => %{"applied" => true, "ref" => "private-case"}
    }

    {:ok, _} = SubjectStatus.update(request)
    seq = Events.latest_seq()
    {:ok, _} = SubjectStatus.update(request)
    assert Events.latest_seq() == seq

    {:ok, _} =
      SubjectStatus.update(%{"subject" => @account, "deactivated" => %{"applied" => true}})

    {:ok, _} = SubjectStatus.update(%{"subject" => @account, "takedown" => %{"applied" => false}})
    assert {:ok, %{entries: [first, repeated, deactivated, restored]}} = Audit.list()
    assert first.subject == @account
    assert first.actor == "admin"
    assert first.operation == "com.atproto.admin.updateSubjectStatus"
    assert first.requested == Map.delete(request, "subject")
    assert first.before["availability"] == "active"
    assert first.after["availability"] == "takendown"
    assert first.after["takedown"]["ref"] == "private-case"
    assert repeated.before == repeated.after
    assert repeated.id != first.id
    assert deactivated.before["underlyingAvailability"] == "active"
    assert deactivated.after["underlyingAvailability"] == "deactivated"
    assert restored.after["availability"] == "deactivated"
    assert restored.before["takedown"]["ref"] == "private-case"
    refute Map.has_key?(restored.after["takedown"], "ref")
    assert {:ok, _, _} = DateTime.from_iso8601(first.time)
  end

  test "record and blob decisions have independent subjects and rollback with state", c do
    {:ok, blob} = Blobs.stage(@did, "audit bytes", "text/plain")

    {:ok, _} =
      Repositories.apply_writes(
        @did,
        [{:put, "com.example.record/one", %{"$type" => "com.example.record"}}],
        c.key
      )

    {:ok, record} = Repositories.get_record(@did, "com.example.record/one")

    subjects = [
      %{
        "$type" => "com.atproto.admin.defs#repoBlobRef",
        "did" => @did,
        "cid" => blob["ref"]["$link"]
      },
      %{
        "$type" => "com.atproto.repo.strongRef",
        "uri" => record.uri,
        "cid" => CID.to_base32(record.cid)
      }
    ]

    for subject <- subjects do
      {:ok, _} =
        SubjectStatus.update(%{
          "subject" => subject,
          "takedown" => %{"applied" => true, "ref" => "first"}
        })

      {:ok, _} =
        SubjectStatus.update(%{
          "subject" => subject,
          "takedown" => %{"applied" => true, "ref" => "second"}
        })

      assert {:error, :cancelled} =
               Repo.transaction(fn ->
                 {:ok, _} =
                   SubjectStatus.update(%{
                     "subject" => subject,
                     "takedown" => %{"applied" => false}
                   })

                 Repo.rollback(:cancelled)
               end)
    end

    assert {:ok, %{entries: entries}} = Audit.list()
    assert length(entries) == 4

    for [first, second] <- Enum.chunk_every(entries, 2) do
      assert first.before == %{"takedown" => %{"applied" => false}}
      assert first.after == %{"takedown" => %{"applied" => true, "ref" => "first"}}
      assert second.before == first.after
      assert second.after == %{"takedown" => %{"applied" => true, "ref" => "second"}}
    end

    assert Enum.map(entries, & &1.subject) == Enum.flat_map(subjects, &[&1, &1])
    assert {:error, :not_found} = Repositories.get_record(@did, "com.example.record/one")
    assert {:error, :blob_taken_down} = Blobs.stage(@did, "audit bytes", "text/plain")
  end

  test "invalid decisions create no audit entry and account updates roll back with the audit" do
    assert {:error, _} =
             SubjectStatus.update(%{"subject" => @account, "takedown" => %{"applied" => "true"}})

    assert {:error, :subject_not_found} =
             SubjectStatus.update(%{
               "subject" => Map.put(@account, "did", "did:web:missing.example.com")
             })

    seq = Events.latest_seq()

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               {:ok, _} =
                 SubjectStatus.update(%{
                   "subject" => @account,
                   "takedown" => %{"applied" => true}
                 })

               Repo.rollback(:cancelled)
             end)

    assert Events.latest_seq() == seq
    assert {:ok, %{status: :active}} = Repositories.get_head(@did)
    assert {:ok, %{entries: []}} = Audit.list()
  end

  test "keyset pages filter by account and preserve IDs as strings without skipping entries" do
    other = "did:web:other-audit.example.com"
    {:ok, _} = Repositories.create(other, SigningKey.generate())

    for did <- [@did, other, @did, other, @did] do
      {:ok, _} = SubjectStatus.update(%{"subject" => Map.put(@account, "did", did)})
    end

    {:ok, %{entries: all}} = Audit.list()
    {:ok, %{entries: first, cursor: cursor}} = Audit.list(2)
    {:ok, %{entries: second, cursor: cursor2}} = Audit.list(2, String.to_integer(cursor))
    {:ok, %{entries: third} = last} = Audit.list(2, String.to_integer(cursor2))
    assert first ++ second ++ third == all
    refute Map.has_key?(last, :cursor)
    assert Enum.all?(all, &is_binary(&1.id))
    {:ok, %{entries: own, cursor: own_cursor}} = Audit.list(2, 0, @did)
    {:ok, %{entries: own_last}} = Audit.list(2, String.to_integer(own_cursor), @did)
    assert own ++ own_last == Enum.filter(all, &(&1.did == @did))

    for {limit, cursor, did} <- [
          {0, 0, nil},
          {1001, 0, nil},
          {1, -1, nil},
          {1, 9_223_372_036_854_775_808, nil},
          {1, 0, "bad"}
        ] do
      assert {:error, :invalid_audit_query} = Audit.list(limit, cursor, did)
    end
  end

  test "request snapshots exclude credentials and private fields are redacted from struct inspection" do
    Repo.transaction(fn ->
      Audit.append!(
        @did,
        @account,
        %{
          "takedown" => %{"applied" => true, "ref" => "secret-reason"},
          "password" => "never-store-password",
          "authorization" => "never-store-token"
        },
        %{},
        %{"ref" => "secret-reason"}
      )
    end)

    row = Repo.one!(AuditEntry)
    refute inspect(row) =~ "secret-reason"
    assert {:ok, %{entries: [entry]}} = Audit.list()
    text = Jason.encode!(entry)
    assert text =~ "secret-reason"
    refute text =~ "never-store"
  end

  test "CLI exports a bounded JSON page and rejects duplicate or malformed arguments" do
    for _ <- 1..2, do: SubjectStatus.update(%{"subject" => @account})

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Moderation.History.run(["--limit", "1", "--did", @did])
      end)

    assert %{"entries" => [entry], "cursor" => cursor} = Jason.decode!(String.trim(output))
    assert entry["did"] == @did

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Moderation.History.run(["--after", cursor])
      end)

    assert %{"entries" => [last]} = Jason.decode!(String.trim(output))
    assert last["id"] != entry["id"]

    for args <- [
          ["--limit", "0"],
          ["--limit", "1001"],
          ["--after", "-1"],
          ["--after", "bad"],
          ["--did", "bad"],
          ["--limit", "1", "--limit", "2"],
          ["--unknown"],
          ["extra"]
        ] do
      assert_raise Mix.Error, fn -> Mix.Tasks.Atoll.Moderation.History.run(args) end
    end
  end
end
