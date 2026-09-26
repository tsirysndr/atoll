defmodule Atoll.PLCRecoveryAuthorityKeysTest do
  use Atoll.DataCase, async: false
  alias Atoll.{KeyRewrap, KeyVault, Multikey, Repositories, SigningKey}

  alias Atoll.Identity.PLC.{
    Operation,
    PendingAuthorityKeys,
    Recoveries,
    Registration,
    Registrations,
    RotationKeys,
    Update,
    Updates
  }

  alias Atoll.Repositories.Events

  setup do
    for name <- [:key_encryption_key, :previous_key_encryption_keys] do
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
    repository = SigningKey.generate()
    high = SigningKey.generate(:p256)
    old = SigningKey.generate()
    new = SigningKey.generate(:p256)
    {:ok, signing} = Multikey.to_did_key(repository.curve, repository.public)
    {:ok, high_id} = Multikey.to_did_key(high.curve, high.public)
    {:ok, expected} = Multikey.to_did_key(old.curve, old.public)

    {:ok, genesis} =
      Operation.create_atproto(
        signing,
        "alice.example.com",
        "https://pds.example.com",
        [high_id, expected],
        old
      )

    {:ok, unsigned} = Operation.successor(genesis.operation)
    {:ok, bad} = Operation.sign(Map.put(unsigned, "alsoKnownAs", ["at://bad.example.com"]), old)
    now = DateTime.utc_now()

    audit = [
      entry(genesis.did, genesis.operation, DateTime.add(now, -60, :second)),
      entry(genesis.did, bad, DateTime.add(now, -30, :second))
    ]

    {:ok, head} = Repositories.create(genesis.did, repository)
    {:ok, _} = KeyVault.store(genesis.did, repository)
    Repo.insert!(%Atoll.Accounts.Profile{did: genesis.did, handle: "alice.example.com"})
    {:ok, _} = Repositories.set_status(genesis.did, :deactivated)
    {:ok, _} = Registrations.stage(genesis.did, genesis.operation, old)
    {:ok, _} = Repositories.set_status(genesis.did, :active)

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
      master: master,
      repository: repository
    }
  end

  test "lost master-key custody permits staging and restoring a supplied authority", c do
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    assert {:error, :key_decryption_failed} = Registrations.rotation_key(c.did)
    assert RotationKeys.public_key(c.did) == {:ok, c.expected}
    {op, cid} = operation(c, c.new)
    seq = Events.latest_seq()
    assert {:ok, :stored} = stage(c, op, c.new)
    row = Repo.get_by!(Update, did: c.did, cid: cid)
    assert {:ok, :unchanged} = stage(c, op, c.new)
    assert Repo.get_by!(Update, did: c.did, cid: cid) == row
    assert PendingAuthorityKeys.fetch(c.did, cid) == {:ok, c.new}
    confirm(c, op, cid)

    assert {:error, :invalid_key_workflow} =
             Repo.transaction(fn -> RotationKeys.adopt_pending!(c.did, cid) end)

    assert {:ok, :ok} = finish(c, cid)
    assert Registrations.rotation_key(c.did) == {:ok, c.new}
    {:ok, public} = Multikey.to_did_key(c.new.curve, c.new.public)
    assert RotationKeys.public_key(c.did) == {:ok, public}
    assert {:error, :key_not_found} = PendingAuthorityKeys.fetch(c.did, cid)
    assert Repositories.get_head(c.did) == {:ok, c.head}
    assert Events.latest_seq() == seq
  end

  test "same-key repair restores corrupt authority custody without changing repository key", c do
    Repo.get!(Registration, c.did)
    |> Ecto.Changeset.change(rotation_envelope: :binary.copy(<<0>>, 61))
    |> Repo.update!(log: false)

    {op, cid} = operation(c, c.old)
    assert {:ok, :stored} = stage(c, op, c.old)
    confirm(c, op, cid)
    assert {:ok, :ok} = finish(c, cid)
    assert Registrations.rotation_key(c.did) == {:ok, c.old}
    assert KeyVault.fetch(c.did) == {:ok, c.repository}
  end

  test "rollback retains pending custody and old retained authority", c do
    {op, cid} = operation(c, c.new)
    {:ok, :stored} = stage(c, op, c.new)

    assert {:error, :plc_update_unconfirmed} =
             Repo.transaction(fn -> RotationKeys.restore_pending!(c.did, cid) end)

    confirm(c, op, cid)

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert :ok = RotationKeys.restore_pending!(c.did, cid)
               Updates.complete!(c.did, cid)
               PendingAuthorityKeys.release!(c.did, cid)
               Repo.rollback(:cancelled)
             end)

    assert Registrations.rotation_key(c.did) == {:ok, c.old}
    assert PendingAuthorityKeys.fetch(c.did, cid) == {:ok, c.new}
    refute Repo.get_by!(Update, did: c.did, cid: cid).completed_at
  end

  test "stale authority metadata and mismatched operation keys leave no journal", c do
    {op, _} = operation(c, c.new)
    {:ok, wrong} = Multikey.to_did_key(c.new.curve, c.new.public)
    assert {:error, :stale_rotation_key} = stage(%{c | expected: wrong}, op, c.new)
    assert {:error, :invalid_key} = stage(c, op, c.old)
    assert Repo.aggregate(Update, :count) == 0
  end

  test "rewrap preserves recovery custody and rejects tampered operation metadata", c do
    {op, cid} = operation(c, c.new)
    {:ok, :stored} = stage(c, op, c.new)
    row = Repo.get_by!(Update, did: c.did, cid: cid)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :previous_key_encryption_keys, [c.master])
    assert {:ok, %{repositories: 1, plc: 2}} = KeyRewrap.batch()
    Application.put_env(:atoll, :previous_key_encryption_keys, [])
    assert PendingAuthorityKeys.fetch(c.did, cid) == {:ok, c.new}
    assert Repo.get_by!(Update, did: c.did, cid: cid).authority_envelope != row.authority_envelope

    Repo.get_by!(Update, did: c.did, cid: cid)
    |> Ecto.Changeset.change(expected_authority_key: "did:key:tampered")
    |> Repo.update!()

    assert {:error, :key_decryption_failed} = PendingAuthorityKeys.fetch(c.did, cid)
  end

  defp finish(c, cid) do
    Repo.transaction(fn ->
      :ok = RotationKeys.restore_pending!(c.did, cid)
      Updates.complete!(c.did, cid)
      PendingAuthorityKeys.release!(c.did, cid)
    end)
  end

  defp stage(c, op, key),
    do: PendingAuthorityKeys.stage_recovery(c.did, c.audit, op, c.expected, key, c.now)

  defp operation(c, key) do
    {:ok, public} = Multikey.to_did_key(key.curve, key.public)
    {:ok, op} = c.unsigned |> Map.put("rotationKeys", [public]) |> Operation.sign(c.high)
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
