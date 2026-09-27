defmodule Atoll.KeyRewrapTest do
  use Atoll.DataCase, async: false
  alias Atoll.{KeyVault, KeyRewrap, MasterKeys, Multikey, Repositories, SigningKey}
  alias Atoll.Moderation.AuditEntry
  alias Atoll.Accounts.Profile
  alias Atoll.Identity.PLC.{Operation, Registration, Registrations}
  alias Atoll.Repositories.{EncryptedKey, Events}

  setup do
    previous =
      Map.new(
        [:key_encryption_key, :previous_key_encryption_keys],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    old = :crypto.strong_rand_bytes(32)
    new = :crypto.strong_rand_bytes(32)
    Application.put_env(:atoll, :key_encryption_key, old)
    Application.put_env(:atoll, :previous_key_encryption_keys, [])

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    %{old: old, new: new}
  end

  test "rewraps both envelope kinds without changing keys, signed genesis, or public events", c do
    for curve <- [:k256, :p256] do
      ctx = account("#{curve}.example.com", curve)
      {:ok, _} = Registrations.stage(ctx.did, ctx.operation, ctx.rotation)
    end

    rows = Repo.all(Registration)

    keys =
      Map.new(rows, fn row ->
        {:ok, key} = KeyVault.fetch(row.did)
        {row.did, key}
      end)

    envelopes = Map.new(Repo.all(EncryptedKey), &{&1.did, &1.envelope})
    seq = Events.latest_seq()
    switch(c)

    for row <- rows do
      assert KeyVault.fetch(row.did) == {:ok, keys[row.did]}
      assert {:ok, _} = Registrations.rotation_key(row.did)
    end

    assert {:ok, %{repositories: 1, plc: 1, scanned: 1, cursor: cursor}} = KeyRewrap.batch(1)
    assert {:ok, %{repositories: 1, plc: 1, scanned: 1} = last} = KeyRewrap.batch(1, cursor)
    refute Map.has_key?(last, :cursor)
    Application.put_env(:atoll, :previous_key_encryption_keys, [])

    for row <- rows do
      assert KeyVault.fetch(row.did) == {:ok, keys[row.did]}
      assert {:ok, rotation} = Registrations.rotation_key(row.did)
      assert rotation.public == row.rotation_public_key
      assert Repo.get!(Registration, row.did).operation == row.operation
      assert Repo.get!(Registration, row.did).cid == row.cid
      refute Repo.get!(EncryptedKey, row.did).envelope == envelopes[row.did]
      refute Repo.get!(Registration, row.did).rotation_envelope == row.rotation_envelope
    end

    assert {:ok, %{repositories: 0, plc: 0, unchanged: 4}} = KeyRewrap.batch()
    assert Events.latest_seq() == seq
    [first, second, unchanged] = Repo.all(from a in AuditEntry, order_by: a.id)
    assert first.operation == "atoll.keys.rewrap"
    assert first.actor == "operator"
    assert first.did == nil
    assert first.subject == %{"kind" => "keyEncryption"}
    assert first.requested == %{"limit" => 1, "after" => nil}
    assert first.before_state == %{"identifiers" => [cursor]}

    assert first.after_state == %{
             "scanned" => 1,
             "repositories" => 1,
             "plc" => 1,
             "totp" => 0,
             "unchanged" => 0,
             "cursor" => cursor
           }

    assert second.requested == %{"limit" => 1, "after" => cursor}
    assert unchanged.after_state["unchanged"] == 4
  end

  test "unreadable PLC envelope rolls back an earlier repository rewrap in the same page", c do
    ctx = account()
    {:ok, _} = Registrations.stage(ctx.did, ctx.operation, ctx.rotation)
    before = Repo.get!(EncryptedKey, ctx.did).envelope

    Repo.get!(Registration, ctx.did)
    |> Ecto.Changeset.change(rotation_envelope: :binary.copy(<<0>>, 61))
    |> Repo.update!()

    switch(c)
    assert {:error, :key_decryption_failed} = KeyRewrap.batch()
    assert Repo.get!(EncryptedKey, ctx.did).envelope == before
    assert Repo.aggregate(AuditEntry, :count) == 0
  end

  test "new writes use only the active key and old keys cannot read rewrapped envelopes", c do
    {:ok, _} = Repositories.create_managed("did:web:old.example.com")
    switch(c)
    {:ok, _} = Repositories.create_managed("did:web:new.example.com")
    assert {:ok, %{repositories: 1, unchanged: 1}} = KeyRewrap.batch()
    Application.put_env(:atoll, :key_encryption_key, c.old)
    Application.put_env(:atoll, :previous_key_encryption_keys, [])

    for did <- ["did:web:old.example.com", "did:web:new.example.com"],
        do: assert(KeyVault.fetch(did) == {:error, :key_decryption_failed})
  end

  test "configuration and CLI validate bounds without printing secrets", c do
    assert MasterKeys.previous_from_env!(nil) == []
    assert MasterKeys.previous_from_env!(Base.encode64(c.old)) == [c.old]

    for value <- [
          "invalid",
          Base.encode64(<<1>>),
          Enum.join(List.duplicate(Base.encode64(c.old), 5), ",")
        ] do
      assert_raise ArgumentError, fn -> MasterKeys.previous_from_env!(value) end
    end

    for args <- [
          ["--limit", "0"],
          ["--limit", "101"],
          ["--after", "bad"],
          ["--limit", "1", "--limit", "2"],
          ["--key", "secret"]
        ] do
      assert_raise Mix.Error, fn -> Mix.Tasks.Atoll.Keys.Rewrap.run(args) end
    end

    {:ok, _} = Repositories.create_managed("did:web:cli.example.com")
    switch(c)
    output = ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Atoll.Keys.Rewrap.run([]) end)
    assert Jason.decode!(String.trim(output))["repositories"] == 1
    refute output =~ Base.encode64(c.old)
    refute output =~ Base.encode64(c.new)
    assert {:error, :invalid_rewrap_options} = KeyRewrap.batch(101)
  end

  test "audit failure rolls back repository envelope updates", c do
    {:ok, _} = Repositories.create_managed("did:web:audit.example.com")
    before = Repo.all(EncryptedKey)
    switch(c)

    Repo.query!(
      "ALTER TABLE moderation_audit_entries ADD CONSTRAINT reject_rewrap_audit CHECK (operation <> 'atoll.keys.rewrap')"
    )

    assert_raise Ecto.ConstraintError, fn -> KeyRewrap.batch() end
    assert Repo.all(EncryptedKey) == before
    assert Repo.aggregate(AuditEntry, :count) == 0
  end

  test "empty pages are audited without inventing affected identifiers" do
    assert {:ok, result} = KeyRewrap.batch()
    entry = Repo.one!(AuditEntry)
    assert entry.before_state == %{"identifiers" => []}
    assert entry.after_state == Jason.decode!(Jason.encode!(result))
  end

  defp switch(c) do
    Application.put_env(:atoll, :key_encryption_key, c.new)
    Application.put_env(:atoll, :previous_key_encryption_keys, [c.old])
  end

  defp account(handle \\ "alice.example.com", curve \\ :k256) do
    repo_key = SigningKey.generate()
    rotation = SigningKey.generate(curve)
    {:ok, signing_id} = Multikey.to_did_key(repo_key.curve, repo_key.public)
    {:ok, rotation_id} = Multikey.to_did_key(rotation.curve, rotation.public)

    {:ok, genesis} =
      Operation.create_atproto(
        signing_id,
        handle,
        "https://pds.example.com",
        [rotation_id],
        rotation
      )

    {:ok, _} = Repositories.create(genesis.did, repo_key)
    {:ok, _} = KeyVault.store(genesis.did, repo_key)
    {:ok, _} = Repositories.set_status(genesis.did, :deactivated)
    Repo.insert!(%Profile{did: genesis.did, handle: handle})
    Map.put(genesis, :rotation, rotation)
  end
end
