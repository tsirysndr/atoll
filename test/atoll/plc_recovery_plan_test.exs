defmodule Atoll.PLCRecoveryPlanTest do
  use ExUnit.Case, async: true
  alias Atoll.{Multikey, SigningKey}
  alias Atoll.Identity.PLC.{AuditLog, Operation, RecoveryPlan}
  @start ~U[2026-01-01 00:00:00.000000Z]

  setup do
    high = SigningKey.generate(:p256)
    low = SigningKey.generate()
    {:ok, high_id} = Multikey.to_did_key(high.curve, high.public)
    {:ok, low_id} = Multikey.to_did_key(low.curve, low.public)

    {:ok, genesis} =
      Operation.create_atproto(
        low_id,
        "alice.example.com",
        "https://pds.example.com",
        [high_id, low_id],
        low
      )

    {:ok, first} = successor(genesis.operation, low, "first.example.com")
    {:ok, last} = successor(first, low, "last.example.com")
    {:ok, recovery} = successor(genesis.operation, high, "restored.example.com")

    entries = [
      entry(genesis.did, genesis.operation, @start),
      entry(genesis.did, first, DateTime.add(@start, 60, :second)),
      entry(genesis.did, last, DateTime.add(@start, 120, :second))
    ]

    %{
      did: genesis.did,
      high: high,
      low: low,
      high_id: high_id,
      genesis: genesis,
      first: first,
      last: last,
      entries: entries,
      recovery: recovery,
      now: DateTime.add(@start, 180, :second)
    }
  end

  test "plans a higher-priority fork and identifies exactly the displaced active suffix", c do
    assert {:ok, plan} = RecoveryPlan.preview(c.did, c.entries, c.recovery, c.now)
    assert plan.previous == c.genesis.cid
    assert plan.expected_head == List.last(c.entries)["cid"]
    assert plan.nullified_cids == Enum.map(tl(c.entries), & &1["cid"])
    assert plan.signer == c.high_id
    assert plan.valid_until == DateTime.add(@start, 60 + 72 * 3600, :second)
    refute plan.tombstoned
    assert {:ok, _} = AuditLog.verify(c.did, c.entries)
  end

  test "accepts the exact deadline and rejects the next microsecond and non-increasing receipt times",
       c do
    deadline = DateTime.add(@start, 60 + 72 * 3600, :second)
    assert {:ok, _} = RecoveryPlan.preview(c.did, c.entries, c.recovery, deadline)

    assert {:error, :invalid_plc_recovery} =
             RecoveryPlan.preview(
               c.did,
               c.entries,
               c.recovery,
               DateTime.add(deadline, 1, :microsecond)
             )

    assert {:error, :invalid_plc_recovery} =
             RecoveryPlan.preview(
               c.did,
               c.entries,
               c.recovery,
               DateTime.add(@start, 120, :second)
             )
  end

  test "rejects ordinary successors, same-priority forks, bad signatures and forged evidence",
       c do
    {:ok, ordinary} = successor(c.last, c.high, "ordinary.example.com")
    {:ok, same_priority} = successor(c.genesis.operation, c.low, "fork.example.com")

    for operation <- [ordinary, same_priority, Map.put(c.recovery, "sig", "bad"), nil] do
      assert {:error, :invalid_plc_recovery} =
               RecoveryPlan.preview(c.did, c.entries, operation, c.now)
    end

    [genesis | rest] = c.entries

    assert {:error, :invalid_plc_recovery} =
             RecoveryPlan.preview(
               c.did,
               [Map.put(genesis, "nullified", true) | rest],
               c.recovery,
               c.now
             )

    assert {:error, :invalid_plc_recovery} =
             RecoveryPlan.preview(
               "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
               c.entries,
               c.recovery,
               c.now
             )

    assert {:error, :invalid_plc_recovery} =
             RecoveryPlan.preview(c.did, List.duplicate(genesis, 1000), c.recovery, c.now)
  end

  test "can recover a lower-priority tombstone using its surviving ancestor", c do
    {:ok, tombstone} =
      Operation.sign(%{"type" => "plc_tombstone", "prev" => c.genesis.cid}, c.low)

    entries = [hd(c.entries), entry(c.did, tombstone, DateTime.add(@start, 60, :second))]
    assert {:ok, %{tombstoned: true}} = AuditLog.verify(c.did, entries)

    assert {:ok, %{tombstoned: false, nullified_cids: [_]}} =
             RecoveryPlan.preview(c.did, entries, c.recovery, c.now)
  end

  test "preserves earlier nullifications and refuses a fork from a nullified operation", c do
    {:ok, cid} = Operation.cid(c.recovery)

    recovered =
      [hd(c.entries)] ++
        Enum.map(tl(c.entries), &Map.put(&1, "nullified", true)) ++
        [entry(c.did, c.recovery, c.now)]

    {:ok, child} = successor(c.recovery, c.low, "child.example.com")
    entries = recovered ++ [entry(c.did, child, DateTime.add(c.now, 60, :second))]
    {:ok, next_recovery} = successor(c.recovery, c.high, "next.example.com")

    assert {:ok, plan} =
             RecoveryPlan.preview(
               c.did,
               entries,
               next_recovery,
               DateTime.add(c.now, 120, :second)
             )

    assert plan.previous == cid
    assert plan.nullified_cids == [List.last(entries)["cid"]]
    {:ok, invalid} = successor(c.first, c.high, "invalid.example.com")

    assert {:error, :invalid_plc_recovery} =
             RecoveryPlan.preview(c.did, entries, invalid, DateTime.add(c.now, 120, :second))

    assert {:error, :invalid_plc_recovery} =
             RecoveryPlan.preview(c.did, recovered, c.recovery, DateTime.add(c.now, 120, :second))
  end

  test "directory preflight verifies fresh audit and latest head before planning", c do
    base = DateTime.add(DateTime.utc_now(), -300, :second)

    entries =
      c.entries
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        Map.put(row, "createdAt", DateTime.to_iso8601(DateTime.add(base, index * 60, :second)))
      end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert String.ends_with?(conn.request_path, "/log/audit")
      Req.Test.json(conn, entries)
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert String.ends_with?(conn.request_path, "/log/last")
      Req.Test.json(conn, c.last)
    end)

    assert {:ok, plan} =
             RecoveryPlan.from_directory(c.did, c.recovery, plug: {Req.Test, __MODULE__})

    assert plan.expected_head == List.last(entries)["cid"]
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, entries))
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, c.genesis.operation))

    assert {:error, :plc_conflict} =
             RecoveryPlan.from_directory(c.did, c.recovery, plug: {Req.Test, __MODULE__})
  end

  defp successor(previous, key, handle) do
    {:ok, unsigned} = Operation.successor(previous)
    Operation.sign(Map.put(unsigned, "alsoKnownAs", ["at://" <> handle]), key)
  end

  defp entry(did, operation, time) do
    {:ok, cid} = Operation.cid(operation)

    %{
      "did" => did,
      "cid" => cid,
      "operation" => operation,
      "nullified" => false,
      "createdAt" => DateTime.to_iso8601(time)
    }
  end
end
