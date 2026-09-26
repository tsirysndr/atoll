defmodule Atoll.PLCRecoverySigningKeysTest do
  use Atoll.DataCase, async: false
  alias Atoll.{KeyRewrap, KeyVault, Multikey, Repositories, SigningKey}
  alias Atoll.Identity.PLC.{Operation, PendingSigningKeys, Recoveries, Update, Updates}
  alias Atoll.Repositories.{EncryptedKey, Events}

  setup do
    for name <- [:key_encryption_key, :previous_key_encryption_keys, :repository_quota] do
      previous = Application.fetch_env(:atoll, name)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end)
    end

    master = :crypto.strong_rand_bytes(32)
    Application.put_env(:atoll, :key_encryption_key, master)
    Application.put_env(:atoll, :previous_key_encryption_keys, [])
    old = SigningKey.generate()
    new = SigningKey.generate(:p256)
    high = SigningKey.generate(:p256)
    low = SigningKey.generate()
    {:ok, expected} = Multikey.to_did_key(old.curve, old.public)
    {:ok, high_id} = Multikey.to_did_key(high.curve, high.public)
    {:ok, low_id} = Multikey.to_did_key(low.curve, low.public)

    {:ok, genesis} =
      Operation.create_atproto(
        expected,
        "alice.example.com",
        "https://pds.example.com",
        [high_id, low_id],
        low
      )

    {:ok, unsigned} = Operation.successor(genesis.operation)
    {:ok, bad} = Operation.sign(Map.put(unsigned, "alsoKnownAs", ["at://bad.example.com"]), low)
    now = DateTime.utc_now()

    audit = [
      entry(genesis.did, genesis.operation, DateTime.add(now, -60, :second)),
      entry(genesis.did, bad, DateTime.add(now, -30, :second))
    ]

    {:ok, head} = Repositories.create(genesis.did, old)

    %{
      did: genesis.did,
      expected: expected,
      old: old,
      new: new,
      high: high,
      unsigned: unsigned,
      audit: audit,
      now: now,
      head: head,
      master: master
    }
  end

  test "recovery stages encrypted custody despite missing old vault, preserving reviewed scope",
       c do
    {op, cid} = operation(c, c.new)
    seq = Events.latest_seq()
    assert {:error, :key_not_found} = KeyVault.fetch(c.did)
    assert {:ok, :stored} = stage(c, op, c.new)
    row = Repo.get_by!(Update, did: c.did, cid: cid)
    assert row.recovery_expected_head == List.last(c.audit)["cid"]
    assert row.expected_signing_key == c.expected
    assert byte_size(row.signing_envelope) == 61
    assert PendingSigningKeys.fetch(c.did, cid) == {:ok, c.new}
    assert {:ok, :unchanged} = stage(c, op, c.new)
    assert Repo.get_by!(Update, did: c.did, cid: cid) == row
    assert {:error, :plc_update_pending} = Updates.submit(c.did, cid)
    assert Repositories.get_head(c.did) == {:ok, c.head}
    assert Events.latest_seq() == seq
  end

  test "same-key recovery repairs missing custody after verified acceptance", c do
    {op, cid} = operation(c, c.old)
    assert {:ok, :stored} = stage(c, op, c.old)
    confirm(c, op, cid)
    seq = Events.latest_seq()

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               {:ok, key} = PendingSigningKeys.fetch(c.did, cid)
               assert {:ok, head} = Repositories.recover_signing_key(c.did, key, c.head.head)
               assert head == c.head
               Updates.complete!(c.did, cid)
               PendingSigningKeys.release!(c.did, cid)
             end)

    assert KeyVault.fetch(c.did) == {:ok, c.old}
    assert {:error, :key_not_found} = PendingSigningKeys.fetch(c.did, cid)
    assert Events.latest_seq() == seq
  end

  test "publication failure retains confirmed recovery custody and a later retry completes", c do
    {op, cid} = operation(c, c.new)
    {:ok, :stored} = stage(c, op, c.new)
    confirm(c, op, cid)
    Application.put_env(:atoll, :repository_quota, max_bytes: 0)
    seq = Events.latest_seq()

    assert {:error, :repository_quota_exceeded} =
             Repositories.recover_signing_key(c.did, c.new, c.head.head)

    assert Repo.get(EncryptedKey, c.did) == nil
    assert PendingSigningKeys.fetch(c.did, cid) == {:ok, c.new}
    refute Repo.get_by!(Update, did: c.did, cid: cid).completed_at
    assert Events.latest_seq() == seq
    Application.delete_env(:atoll, :repository_quota)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               assert {:ok, _} = Repositories.recover_signing_key(c.did, c.new, c.head.head)
               Updates.complete!(c.did, cid)
               PendingSigningKeys.release!(c.did, cid)
             end)

    assert KeyVault.fetch(c.did) == {:ok, c.new}
    assert {:error, :key_not_found} = PendingSigningKeys.fetch(c.did, cid)
    assert {:ok, [%{kind: :sync}]} = Events.list_after(seq)
  end

  test "stale expected key, mismatched private material and invalid recovery leave no custody",
       c do
    {op, _} = operation(c, c.new)
    {:ok, wrong} = Multikey.to_did_key(c.new.curve, c.new.public)
    assert {:error, :stale_signing_key} = stage(%{c | expected: wrong}, op, c.new)
    assert {:error, :invalid_key} = stage(c, op, %{c.new | public: c.old.public})
    assert {:error, _} = stage(c, Map.put(op, "sig", "invalid"), c.new)
    assert Repo.aggregate(Update, :count) == 0
  end

  test "rewrapping preserves encrypted recovery custody without the old vault", c do
    {op, cid} = operation(c, c.new)
    {:ok, :stored} = stage(c, op, c.new)
    row = Repo.get_by!(Update, did: c.did, cid: cid)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :previous_key_encryption_keys, [c.master])
    assert {:ok, %{repositories: 0, plc: 1}} = KeyRewrap.batch()
    Application.put_env(:atoll, :previous_key_encryption_keys, [])
    assert PendingSigningKeys.fetch(c.did, cid) == {:ok, c.new}
    assert Repo.get_by!(Update, did: c.did, cid: cid).signing_envelope != row.signing_envelope
    assert Repo.get_by!(Update, did: c.did, cid: cid).operation == row.operation
  end

  test "custody and recovery staging roll back together", c do
    {op, _} = operation(c, c.new)

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, :stored} = stage(c, op, c.new)
               Repo.rollback(:cancelled)
             end)

    assert Repo.aggregate(Update, :count) == 0
    assert {:error, :key_not_found} = KeyVault.fetch(c.did)
  end

  defp stage(c, op, key),
    do: PendingSigningKeys.stage_recovery(c.did, c.audit, op, c.expected, key, c.now)

  defp operation(c, key) do
    {:ok, public} = Multikey.to_did_key(key.curve, key.public)

    {:ok, op} =
      c.unsigned |> put_in(["verificationMethods", "atproto"], public) |> Operation.sign(c.high)

    {:ok, cid} = Operation.cid(op)
    {op, cid}
  end

  defp confirm(c, op, cid) do
    accepted = [
      hd(c.audit),
      Map.put(List.last(c.audit), "nullified", true),
      entry(c.did, op, c.now)
    ]

    Req.Test.expect(__MODULE__, &Req.Test.json(&1, accepted))
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, op))
    assert {:ok, %{confirmed: true}} = Recoveries.submit(c.did, cid, plug: {Req.Test, __MODULE__})
  end

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
