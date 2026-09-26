defmodule Atoll.PLCPendingAuthorityKeysTest do
  use Atoll.DataCase, async: false
  alias Atoll.{KeyRewrap, KeyVault, Multikey, Repositories, SigningKey}

  alias Atoll.Identity.PLC.{
    Operation,
    PendingAuthorityKeys,
    Registrations,
    RotationKeys,
    Update,
    Updates
  }

  alias Atoll.Repositories.{Events, Head}

  setup do
    for name <- [:key_encryption_key, :previous_key_encryption_keys] do
      prior = Application.fetch_env(:atoll, name)

      on_exit(fn ->
        case prior do
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
    rotation = SigningKey.generate()
    {:ok, repository} = Multikey.to_did_key(old.curve, old.public)
    {:ok, expected} = Multikey.to_did_key(rotation.curve, rotation.public)
    {:ok, public} = Multikey.to_did_key(new.curve, new.public)
    {:ok, rotating} = Multikey.to_did_key(rotation.curve, rotation.public)
    {:ok, backup} = Multikey.to_did_key(:k256, SigningKey.generate().public)
    {:ok, other} = Multikey.to_did_key(:k256, SigningKey.generate().public)

    {:ok, genesis} =
      Operation.create_atproto(
        repository,
        "alice.example.com",
        "https://pds.example.com",
        [backup, rotating, other],
        rotation
      )

    {:ok, head} = Repositories.create(genesis.did, old)
    {:ok, _} = KeyVault.store(genesis.did, old)
    Repo.insert!(%Atoll.Accounts.Profile{did: genesis.did, handle: "alice.example.com"})
    {:ok, _} = Repositories.set_status(genesis.did, :deactivated)
    {:ok, _} = Registrations.stage(genesis.did, genesis.operation, rotation)
    {:ok, _} = Repositories.set_status(genesis.did, :active)

    {:ok, operation} =
      genesis.operation
      |> Map.delete("sig")
      |> Map.put("prev", genesis.cid)
      |> Map.put("rotationKeys", [backup, public, other])
      |> Operation.sign(rotation)

    {:ok, cid} = Operation.cid(operation)

    audit = [
      %{
        "did" => genesis.did,
        "cid" => genesis.cid,
        "operation" => genesis.operation,
        "nullified" => false,
        "createdAt" => "2026-01-01T00:00:00Z"
      }
    ]

    %{
      did: genesis.did,
      old: old,
      new: new,
      expected: expected,
      operation: operation,
      cid: cid,
      audit: audit,
      master: master,
      rotation: rotation,
      head: head
    }
  end

  test "stages an immutable encrypted retry without changing the active key or events", c do
    seq = Events.latest_seq()
    assert {:ok, :stored} = stage(c)
    row = Repo.get_by!(Update, did: c.did, cid: c.cid)
    assert byte_size(row.authority_envelope) == 61
    refute inspect(row) =~ Base.encode64(c.new.private)
    assert PendingAuthorityKeys.fetch(c.did, c.cid) == {:ok, c.new}
    assert {:ok, :unchanged} = stage(c)
    assert Repo.get_by!(Update, did: c.did, cid: c.cid) == row
    assert KeyVault.fetch(c.did) == {:ok, c.old}
    assert Repositories.get_head(c.did) == {:ok, c.head}
    assert Events.latest_seq() == seq

    assert {:error, :pending_key_not_completed} =
             Repo.transaction(fn -> PendingAuthorityKeys.release!(c.did, c.cid) end)

    assert PendingAuthorityKeys.fetch(c.did, c.cid) == {:ok, c.new}
  end

  test "bad key and stale expected key never leave a journal row", c do
    assert {:error, :invalid_key} = stage(%{c | new: SigningKey.generate()})
    {:ok, wrong} = Multikey.to_did_key(:k256, SigningKey.generate().public)
    assert {:error, :stale_rotation_key} = stage(%{c | expected: wrong})
    assert Repo.aggregate(Update, :count) == 0

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, :stored} = stage(c)
               Repo.rollback(:cancelled)
             end)

    assert Repo.aggregate(Update, :count) == 0
  end

  test "custody rejects authority priority changes and unrelated identity mutations", c do
    for unsigned <- [
          Map.put(
            Map.delete(c.operation, "sig"),
            "rotationKeys",
            Enum.reverse(c.operation["rotationKeys"])
          ),
          Map.put(Map.delete(c.operation, "sig"), "alsoKnownAs", ["at://other.example.com"])
        ] do
      {:ok, op} = Operation.sign(unsigned, c.rotation)
      assert {:error, :invalid_rotation_key} = stage(%{c | operation: op})
      assert Repo.aggregate(Update, :count) == 0
    end
  end

  test "envelope rejects operation and expected-key metadata tampering", c do
    {:ok, :stored} = stage(c)
    row = Repo.get_by!(Update, did: c.did, cid: c.cid)
    row |> Ecto.Changeset.change(expected_authority_key: "did:key:tampered") |> Repo.update!()
    assert {:error, :key_decryption_failed} = PendingAuthorityKeys.fetch(c.did, c.cid)

    Repo.get_by!(Update, did: c.did, cid: c.cid)
    |> Ecto.Changeset.change(
      operation: Map.put(row.operation, "sig", "bad"),
      expected_authority_key: row.expected_authority_key
    )
    |> Repo.update!()

    assert {:error, :key_decryption_failed} = PendingAuthorityKeys.fetch(c.did, c.cid)
  end

  test "master-key rewrap preserves pending operation and survives removing fallback", c do
    {:ok, :stored} = stage(c)
    row = Repo.get_by!(Update, did: c.did, cid: c.cid)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :previous_key_encryption_keys, [c.master])
    assert PendingAuthorityKeys.fetch(c.did, c.cid) == {:ok, c.new}
    assert {:ok, %{repositories: 1, plc: 2}} = KeyRewrap.batch()
    Application.put_env(:atoll, :previous_key_encryption_keys, [])
    assert PendingAuthorityKeys.fetch(c.did, c.cid) == {:ok, c.new}
    updated = Repo.get_by!(Update, did: c.did, cid: c.cid)
    assert updated.operation == row.operation
    assert updated.authority_envelope != row.authority_envelope
    assert {:ok, %{repositories: 0, plc: 0, unchanged: 3}} = KeyRewrap.batch()
  end

  test "only completed matching local publication can release custody; rollback preserves it",
       c do
    {:ok, :stored} = stage(c)
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, c.operation) end)
    assert {:ok, %{confirmed: true}} = Updates.submit(c.did, c.cid, plug: {Req.Test, __MODULE__})

    finish = fn ->
      assert :ok = RotationKeys.adopt_pending!(c.did, c.cid)
      Updates.complete!(c.did, c.cid)
      PendingAuthorityKeys.release!(c.did, c.cid)
    end

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               finish.()
               Repo.rollback(:cancelled)
             end)

    assert PendingAuthorityKeys.fetch(c.did, c.cid) == {:ok, c.new}
    assert KeyVault.fetch(c.did) == {:ok, c.old}
    assert {:ok, :ok} = Repo.transaction(finish)
    assert {:error, :key_not_found} = PendingAuthorityKeys.fetch(c.did, c.cid)
    assert Registrations.rotation_key(c.did) == {:ok, c.new}
    {:ok, successor} = Operation.successor(c.operation)
    {:ok, signed} = Operation.sign(successor, c.new)
    assert {:ok, _} = Operation.verify_update(c.operation, signed)
    {:ok, obsolete} = Operation.sign(successor, c.rotation)
    assert {:error, _} = Operation.verify_update(c.operation, obsolete)
    assert KeyVault.fetch(c.did) == {:ok, c.old}
    assert Repo.get_by!(Update, did: c.did, cid: c.cid).authority_public_key == c.new.public
    assert {:ok, :ok} = Repo.transaction(fn -> PendingAuthorityKeys.release!(c.did, c.cid) end)
  end

  test "ambiguous submission retains the encrypted key for an exact retry", c do
    {:ok, :stored} = stage(c)
    row = Repo.get_by!(Update, did: c.did, cid: c.cid)
    Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, row.previous) end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      Req.Test.transport_error(conn, :timeout)
    end)

    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :plc_unavailable} = Updates.submit(c.did, c.cid, plug: {Req.Test, __MODULE__})
    assert PendingAuthorityKeys.fetch(c.did, c.cid) == {:ok, c.new}

    assert Repo.get_by!(Update, did: c.did, cid: c.cid).authority_envelope ==
             row.authority_envelope

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, c.operation)
    end)

    assert {:ok, %{confirmed: true}} = Updates.submit(c.did, c.cid, plug: {Req.Test, __MODULE__})
    assert PendingAuthorityKeys.fetch(c.did, c.cid) == {:ok, c.new}
    assert KeyVault.fetch(c.did) == {:ok, c.old}
  end

  test "unreadable pending custody aborts the whole master-key rewrap page", c do
    {:ok, :stored} = stage(c)
    old_envelope = Repo.get!(Atoll.Repositories.EncryptedKey, c.did).envelope
    row = Repo.get_by!(Update, did: c.did, cid: c.cid)

    row
    |> Ecto.Changeset.change(authority_envelope: :binary.copy(<<0>>, 61))
    |> Repo.update!(log: false)

    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :previous_key_encryption_keys, [c.master])
    assert {:error, :key_decryption_failed} = KeyRewrap.batch()
    assert Repo.get!(Atoll.Repositories.EncryptedKey, c.did).envelope == old_envelope
  end

  test "generic PLC submission cannot complete a staged authority-key workflow", c do
    previous = Application.fetch_env(:atoll, :session_signing_key)
    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

    on_exit(fn ->
      AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], [])

      case previous do
        {:ok, value} -> Application.put_env(:atoll, :session_signing_key, value)
        :error -> Application.delete_env(:atoll, :session_signing_key)
      end
    end)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "https", host: "pds.example.com", port: 443)}
      ],
      []
    )

    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

    Repo.get!(Atoll.Identity.PLC.Registration, c.did)
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now(), completed_at: DateTime.utc_now())
    |> Repo.update!()

    {:ok, pair} = Atoll.Accounts.Sessions.create_for_account(c.did)
    {:ok, :stored} = stage(c)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"

      if String.ends_with?(conn.request_path, "/log/audit"),
        do: Req.Test.json(conn, c.audit),
        else: Req.Test.json(conn, hd(c.audit)["operation"])
    end)

    assert {:error, :plc_update_pending} =
             Atoll.Identity.PLC.Submission.submit(
               pair.access_jwt,
               %{"operation" => c.operation},
               plug: {Req.Test, __MODULE__},
               txt_lookup: fn _ -> [["did=" <> c.did]] end
             )

    refute Repo.get_by!(Update, did: c.did, cid: c.cid).completed_at
    assert PendingAuthorityKeys.fetch(c.did, c.cid) == {:ok, c.new}
    assert Registrations.rotation_key(c.did) == {:ok, c.rotation}
  end

  test "account deletion cascades pending custody", c do
    {:ok, :stored} = stage(c)
    Repo.delete!(Repo.get!(Head, c.did))
    assert Repo.aggregate(Update, :count) == 0
    assert {:error, :key_not_found} = PendingAuthorityKeys.fetch(c.did, c.cid)
  end

  defp stage(c), do: PendingAuthorityKeys.stage(c.did, c.audit, c.operation, c.expected, c.new)
end
