defmodule Atoll.PLCRecoveriesTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Multikey, Repositories, SigningKey}
  alias Atoll.Identity.PLC.{Operation, Recoveries, Update, Updates}
  alias Atoll.Repositories.{Events, Head}

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

    {:ok, unsigned} = Operation.successor(genesis.operation)
    {:ok, bad} = Operation.sign(Map.put(unsigned, "alsoKnownAs", ["at://bad.example.com"]), low)

    {:ok, recovery} =
      Operation.sign(Map.put(unsigned, "alsoKnownAs", ["at://restored.example.com"]), high)

    {:ok, cid} = Operation.cid(recovery)
    now = DateTime.utc_now()

    audit = [
      entry(genesis.did, genesis.operation, DateTime.add(now, -60, :second)),
      entry(genesis.did, bad, DateTime.add(now, -30, :second))
    ]

    {:ok, head} = Repositories.create(genesis.did, low)

    directory =
      start_supervised!(
        {Agent,
         fn ->
           %{
             audit: audit,
             last: bad,
             posts: 0,
             ambiguous: false,
             unavailable: false,
             reject: false
           }
         end}
      )

    Req.Test.stub(__MODULE__, fn conn ->
      state = Agent.get(directory, & &1)

      cond do
        state.unavailable ->
          Req.Test.transport_error(conn, :timeout)

        conn.method == "POST" ->
          {:ok, bytes, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(bytes) == recovery
          Agent.update(directory, &%{&1 | posts: &1.posts + 1})

          if state.reject do
            Plug.Conn.send_resp(conn, 400, "rejected")
          else
            [first | removed] = state.audit

            audit =
              [first | Enum.map(removed, &Map.put(&1, "nullified", true))] ++
                [entry(genesis.did, recovery, DateTime.utc_now())]

            Agent.update(
              directory,
              &%{&1 | audit: audit, last: recovery, unavailable: state.ambiguous}
            )

            if state.ambiguous,
              do: Req.Test.transport_error(conn, :timeout),
              else: Req.Test.json(conn, %{})
          end

        String.ends_with?(conn.request_path, "/log/audit") ->
          Req.Test.json(conn, state.audit)

        true ->
          Req.Test.json(conn, state.last)
      end
    end)

    %{
      did: genesis.did,
      cid: cid,
      audit: audit,
      recovery: recovery,
      bad: bad,
      head: head,
      now: now,
      low: low,
      directory: directory,
      opts: [plug: {Req.Test, __MODULE__}]
    }
  end

  test "stages immutable reviewed scope without local publication and blocks ordinary submit",
       c do
    seq = Events.latest_seq()

    assert {:ok, %{expected_head: expected, nullified_cids: [expected], confirmed: false}} =
             stage(c)

    row = Repo.get_by!(Update, did: c.did, cid: c.cid)
    assert {:ok, _} = stage(c)
    assert Repo.get_by!(Update, did: c.did, cid: c.cid) == row
    assert {:error, :plc_update_pending} = Updates.submit(c.did, c.cid, c.opts)
    assert {:ok, _} = Recoveries.submit(c.did, c.cid, c.opts)
    accepted = Agent.get(c.directory, & &1.audit)
    assert {:error, :plc_update_pending} = Updates.stage(c.did, accepted, c.recovery)
    assert Repositories.get_head(c.did) == {:ok, c.head}
    assert Events.latest_seq() == seq
    refute Repo.get_by!(Update, did: c.did, cid: c.cid).completed_at
  end

  test "ambiguous accepted submission retries read-only and preserves first confirmation", c do
    {:ok, _} = stage(c)
    Agent.update(c.directory, &%{&1 | ambiguous: true})
    assert {:error, :plc_unavailable} = Recoveries.submit(c.did, c.cid, c.opts)
    row = Repo.get_by!(Update, did: c.did, cid: c.cid)
    assert row.operation == c.recovery
    refute row.confirmed_at
    Agent.update(c.directory, &%{&1 | unavailable: false})
    assert {:ok, %{confirmed: true, completed: false}} = Recoveries.submit(c.did, c.cid, c.opts)
    confirmed = Repo.get_by!(Update, did: c.did, cid: c.cid).confirmed_at
    assert {:ok, _} = Recoveries.submit(c.did, c.cid, c.opts)
    assert Repo.get_by!(Update, did: c.did, cid: c.cid).confirmed_at == confirmed
    assert Agent.get(c.directory, & &1.posts) == 1
  end

  test "a changed head cannot expand the reviewed displaced suffix", c do
    {:ok, _} = stage(c)
    {:ok, unsigned} = Operation.successor(c.bad)

    {:ok, next} =
      Operation.sign(Map.put(unsigned, "alsoKnownAs", ["at://later.example.com"]), c.low)

    audit = c.audit ++ [entry(c.did, next, DateTime.add(c.now, -1, :second))]
    Agent.update(c.directory, &%{&1 | last: next, audit: audit})
    assert {:error, :plc_conflict} = Recoveries.submit(c.did, c.cid, c.opts)
    assert {:error, :plc_recovery_conflict} = Recoveries.stage(c.did, audit, c.recovery, c.now)
    assert Agent.get(c.directory, & &1.posts) == 0

    assert Repo.get_by!(Update, did: c.did, cid: c.cid).recovery_nullified_cids == [
             List.last(c.audit)["cid"]
           ]
  end

  test "expiry prevents posting but previously accepted recovery remains confirmable", c do
    expired =
      Enum.map(c.audit, fn row ->
        {:ok, time, 0} = DateTime.from_iso8601(row["createdAt"])
        Map.put(row, "createdAt", DateTime.to_iso8601(DateTime.add(time, -73 * 3600, :second)))
      end)

    assert {:ok, _} =
             Recoveries.stage(
               c.did,
               expired,
               c.recovery,
               DateTime.add(c.now, -73 * 3600, :second)
             )

    Agent.update(c.directory, &%{&1 | audit: expired})
    assert {:error, :invalid_plc_recovery} = Recoveries.submit(c.did, c.cid, c.opts)
    assert Agent.get(c.directory, & &1.posts) == 0
    assert Repo.get_by!(Update, did: c.did, cid: c.cid).operation == c.recovery

    accepted = [
      hd(expired),
      Map.put(List.last(expired), "nullified", true),
      entry(c.did, c.recovery, DateTime.add(c.now, -73 * 3600, :second))
    ]

    Agent.update(c.directory, &%{&1 | audit: accepted, last: c.recovery})
    assert {:ok, %{confirmed: true}} = Recoveries.submit(c.did, c.cid, c.opts)
    assert Agent.get(c.directory, & &1.posts) == 0
  end

  test "an in-flight extra operation is detected after acceptance and on retry", c do
    {:ok, _} = stage(c)
    {:ok, unsigned} = Operation.successor(c.bad)

    {:ok, next} =
      Operation.sign(Map.put(unsigned, "alsoKnownAs", ["at://racing.example.com"]), c.low)

    Req.Test.expect(__MODULE__, &Req.Test.json(&1, c.audit))
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, c.bad))

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"

      accepted = [
        hd(c.audit),
        Map.put(List.last(c.audit), "nullified", true),
        Map.put(entry(c.did, next, DateTime.add(c.now, -1, :second)), "nullified", true),
        entry(c.did, c.recovery, DateTime.utc_now())
      ]

      Agent.update(c.directory, &%{&1 | audit: accepted, last: c.recovery})
      Req.Test.json(conn, %{})
    end)

    assert {:error, :plc_recovery_conflict} = Recoveries.submit(c.did, c.cid, c.opts)
    refute Repo.get_by!(Update, did: c.did, cid: c.cid).confirmed_at
    assert {:error, :plc_recovery_conflict} = Recoveries.submit(c.did, c.cid, c.opts)
    assert Repositories.get_head(c.did) == {:ok, c.head}
  end

  test "a changed directory timestamp cannot extend the reviewed deadline", c do
    {:ok, _} = stage(c)
    [first, last] = c.audit
    shifted = Map.put(last, "createdAt", DateTime.to_iso8601(DateTime.add(c.now, -20, :second)))
    Agent.update(c.directory, &%{&1 | audit: [first, shifted]})
    assert {:error, :plc_recovery_conflict} = Recoveries.submit(c.did, c.cid, c.opts)
    assert Agent.get(c.directory, & &1.posts) == 0
  end

  test "rejection never confirms and recovery submit refuses an open transaction", c do
    {:ok, _} = stage(c)
    Agent.update(c.directory, &%{&1 | reject: true})
    assert {:error, :plc_rejected} = Recoveries.submit(c.did, c.cid, c.opts)
    refute Repo.get_by!(Update, did: c.did, cid: c.cid).confirmed_at

    assert {:ok, {:error, :plc_update_inside_transaction}} =
             Repo.transaction(fn -> Recoveries.submit(c.did, c.cid, c.opts) end)
  end

  test "ordinary and recovery journals share the single pending-update reservation", c do
    assert {:ok, _} = Updates.stage(c.did, c.audit, c.bad)
    assert {:error, :plc_update_pending} = stage(c)
    assert Repo.aggregate(Update, :count) == 1
  end

  test "staging rolls back with caller state and account deletion cascades custody", c do
    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, _} = stage(c)
               Repo.rollback(:cancelled)
             end)

    assert Repo.aggregate(Update, :count) == 0
    {:ok, _} = stage(c)
    Repo.delete!(Repo.get!(Head, c.did))
    assert Repo.aggregate(Update, :count) == 0
    assert {:error, :plc_recovery_not_found} = Recoveries.submit(c.did, c.cid, c.opts)
  end

  defp stage(c), do: Recoveries.stage(c.did, c.audit, c.recovery, c.now)

  defp entry(did, op, time) do
    {:ok, cid} = Operation.cid(op)

    %{
      "did" => did,
      "cid" => cid,
      "operation" => op,
      "nullified" => false,
      "createdAt" => DateTime.to_iso8601(time)
    }
  end
end
