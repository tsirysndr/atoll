defmodule Atoll.PLCActiveUpdatesTest do
  use Atoll.DataCase, async: false
  alias Atoll.{KeyVault, Multikey, Repositories, SigningKey}
  alias Atoll.Accounts.{Profile, Sessions}
  alias Atoll.Identity.{HandleChanges, HandleReservation}
  alias Atoll.Identity.PLC.{ActiveUpdates, Operation, Update, Updates}

  setup do
    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "https", host: "pds.example.com", port: 443)}
      ],
      []
    )

    settings = [:pds, :key_encryption_key, :session_signing_key]
    prior = Map.new(settings, &{&1, Application.fetch_env(:atoll, &1)})
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

    Application.put_env(:atoll, :pds,
      did: "did:web:pds.example.com",
      available_user_domains: [".example.com"]
    )

    on_exit(fn ->
      AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], [])

      for {name, value} <- prior do
        case value do
          {:ok, val} -> Application.put_env(:atoll, name, val)
          :error -> Application.delete_env(:atoll, name)
        end
      end
    end)

    key = SigningKey.generate()
    rotation = SigningKey.generate()
    {:ok, public} = Multikey.to_did_key(key.curve, key.public)
    {:ok, rotating} = Multikey.to_did_key(rotation.curve, rotation.public)

    {:ok, genesis} =
      Operation.create_atproto(
        public,
        "alice.example.com",
        AtollWeb.Endpoint.url(),
        [rotating],
        rotation
      )

    {:ok, _} = Repositories.create(genesis.did, key)
    {:ok, :stored} = KeyVault.store(genesis.did, key)
    Repo.insert!(%Profile{did: genesis.did, handle: "alice.example.com"})
    {:ok, pair} = Sessions.create_for_account(genesis.did)
    audit = [entry(genesis.did, genesis.operation, "2026-01-01T00:00:00Z")]
    %{did: genesis.did, genesis: genesis, audit: audit, rotation: rotation, pair: pair}
  end

  test "completes active ancestor handle work without POST and retries without duplicate events",
       c do
    pending = stage(c, "bob.example.com")

    advanced =
      successor(
        pending.operation,
        c.rotation,
        &Map.put(&1, "alsoKnownAs", ["at://bob.example.com", "https://profile.example.com"])
      )

    expected = proof(c, pending, advanced)
    {:ok, _} = Repositories.set_status(c.did, :deactivated)
    before_seq = Atoll.Repositories.Events.latest_seq()
    assert {:ok, %{result: :completed}} = reconcile(c, pending.cid, expected)
    row = Repo.get_by!(Update, did: c.did, cid: pending.cid)
    assert row.confirmed_at && row.completed_at
    assert Repo.get!(Profile, c.did).handle == "bob.example.com"
    assert Repo.get!(Atoll.Repositories.Head, c.did).status == :deactivated
    refute Repo.get(HandleReservation, "bob.example.com")
    assert Atoll.Repositories.Events.latest_seq() == before_seq + 1
    assert {:ok, %{result: :already_completed}} = reconcile(c, pending.cid, expected)
    assert Atoll.Repositories.Events.latest_seq() == before_seq + 1
    audit = Repo.one!(Atoll.Moderation.AuditEntry)
    assert audit.operation == "atoll.plc.reconcileActive"
    assert audit.actor == "operator"
    assert audit.requested["observedHead"] == expected
  end

  test "generic submission journals reconcile when profile already matches", c do
    op = successor(c.genesis.operation, c.rotation, & &1)
    {:ok, journal} = Updates.stage(c.did, c.audit, op)
    pending = %{operation: op, cid: journal.cid}

    advanced =
      successor(
        op,
        c.rotation,
        &put_in(&1, ["services", "extra"], %{
          "type" => "ExampleService",
          "endpoint" => "https://extra.example.com"
        })
      )

    expected = proof(c, pending, advanced)
    assert {:ok, %{result: :completed}} = reconcile(c, journal.cid, expected)
    assert Repo.get!(Profile, c.did).handle == "alice.example.com"
  end

  test "changed identity and stale expectations retain pending custody and reservations", c do
    pending = stage(c, "bob.example.com")
    {:ok, other_key} = Multikey.to_did_key(:k256, SigningKey.generate().public)

    for change <- [
          &Map.put(&1, "alsoKnownAs", ["at://different.example.com"]),
          &put_in(&1, ["verificationMethods", "atproto"], other_key),
          &put_in(&1, ["services", "atproto_pds", "endpoint"], "https://other.example.com")
        ] do
      advanced = successor(pending.operation, c.rotation, change)
      expected = proof(c, pending, advanced)
      assert {:error, :plc_conflict} = reconcile(c, pending.cid, expected)
      assert {:error, :plc_conflict} = reconcile(c, pending.cid, pending.cid)
    end

    assert Repo.get!(Profile, c.did).handle == "alice.example.com"
    assert Repo.get!(HandleReservation, "bob.example.com").cid == pending.cid
    assert is_nil(Repo.get_by!(Update, did: c.did, cid: pending.cid).completed_at)
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 0
  end

  test "concurrent profile changes and unreadable local key prevent reconciliation", c do
    pending = stage(c, "bob.example.com")
    advanced = successor(pending.operation, c.rotation, & &1)
    expected = proof(c, pending, advanced)
    profile = Repo.get!(Profile, c.did)
    profile |> Ecto.Changeset.change(handle: "interim.example.com") |> Repo.update!()
    assert {:error, :plc_conflict} = reconcile(c, pending.cid, expected)
    Repo.get!(Profile, c.did) |> Ecto.Changeset.change(handle: profile.handle) |> Repo.update!()
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    assert {:error, :key_decryption_failed} = reconcile(c, pending.cid, expected)
    assert is_nil(Repo.get_by!(Update, did: c.did, cid: pending.cid).confirmed_at)
    assert Repo.get(HandleReservation, "bob.example.com")
  end

  test "absent operations and unverified forward handles remain pending", c do
    pending = stage(c, "bob.example.com")

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"

      Req.Test.json(
        conn,
        if(String.ends_with?(conn.request_path, "/log/audit"),
          do: c.audit,
          else: c.genesis.operation
        )
      )
    end)

    assert {:error, :plc_conflict} = reconcile(c, pending.cid, c.genesis.cid)
    advanced = successor(pending.operation, c.rotation, & &1)
    expected = proof(c, pending, advanced)
    Application.put_env(:atoll, :pds, did: "did:web:pds.example.com", available_user_domains: [])

    assert {:error, :plc_conflict} =
             ActiveUpdates.reconcile(c.did, pending.cid, expected,
               plug: {Req.Test, __MODULE__},
               txt_lookup: fn _ -> [["did=did:web:someone.example.com"]] end
             )

    assert is_nil(Repo.get_by!(Update, did: c.did, cid: pending.cid).completed_at)
    assert Repo.get(HandleReservation, "bob.example.com")
  end

  defp stage(c, handle) do
    operation =
      successor(c.genesis.operation, c.rotation, &Map.put(&1, "alsoKnownAs", ["at://" <> handle]))

    {:ok, journal} = HandleChanges.stage(c.pair.access_jwt, handle, c.audit, operation)
    %{operation: operation, cid: journal.cid}
  end

  defp successor(previous, key, change) do
    {:ok, unsigned} = Operation.successor(previous)
    {:ok, signed} = Operation.sign(change.(unsigned), key)
    signed
  end

  defp entry(did, operation, date) do
    {:ok, cid} = Operation.cid(operation)

    %{
      "did" => did,
      "cid" => cid,
      "operation" => operation,
      "createdAt" => date,
      "nullified" => false
    }
  end

  defp proof(c, pending, advanced) do
    audit =
      c.audit ++
        [
          entry(c.did, pending.operation, "2026-01-02T00:00:00Z"),
          entry(c.did, advanced, "2026-01-03T00:00:00Z")
        ]

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"

      Req.Test.json(
        conn,
        if(String.ends_with?(conn.request_path, "/log/audit"), do: audit, else: advanced)
      )
    end)

    {:ok, cid} = Operation.cid(advanced)
    cid
  end

  defp reconcile(c, cid, head),
    do: ActiveUpdates.reconcile(c.did, cid, head, plug: {Req.Test, __MODULE__})
end
