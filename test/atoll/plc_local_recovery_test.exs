defmodule Atoll.PLCLocalRecoveryTest do
  use Atoll.DataCase, async: false
  alias Atoll.{KeyVault, Multikey, Repositories, SigningKey}
  alias Atoll.Accounts.{AppPasswords, AppPassword, Profile, Session, Sessions}
  alias Atoll.Identity.PLC.{LocalRecovery, Operation, Registrations, Update}
  alias Atoll.Repositories.Events

  setup do
    for name <- [
          :key_encryption_key,
          :session_signing_key,
          :identity_resolution_options,
          :plc_submission_options,
          :repository_quota
        ] do
      prior = Application.fetch_env(:atoll, name)

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end)
    end

    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))
    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "https", host: "pds.example.com", port: 443)}
      ],
      []
    )

    on_exit(fn -> AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], []) end)
    key = SigningKey.generate()
    {:ok, key_id} = Multikey.to_did_key(key.curve, key.public)
    high = SigningKey.generate(:p256)
    low = SigningKey.generate()
    {:ok, high_id} = Multikey.to_did_key(high.curve, high.public)
    {:ok, low_id} = Multikey.to_did_key(low.curve, low.public)

    {:ok, genesis} =
      Operation.create_atproto(
        key_id,
        "alice.example.com",
        "https://pds.example.com",
        [high_id, low_id],
        low
      )

    {:ok, unsigned} = Operation.successor(genesis.operation)
    {:ok, bad} = Operation.sign(Map.put(unsigned, "alsoKnownAs", ["at://bad.example.com"]), low)

    {:ok, recovery} =
      Operation.sign(Map.put(unsigned, "rotationKeys", [high_id]), high)

    {:ok, cid} = Operation.cid(recovery)
    now = DateTime.utc_now()

    audit = [
      entry(genesis.did, genesis.operation, DateTime.add(now, -60, :second)),
      entry(genesis.did, bad, DateTime.add(now, -30, :second))
    ]

    {:ok, head} = Repositories.create(genesis.did, key)
    {:ok, _} = KeyVault.store(genesis.did, key)
    Repo.insert!(%Profile{did: genesis.did, handle: "alice.example.com"})
    {:ok, _} = Repositories.set_status(genesis.did, :deactivated)
    {:ok, _} = Registrations.stage(genesis.did, genesis.operation, high)

    Repo.get!(Atoll.Identity.PLC.Registration, genesis.did)
    |> Ecto.Changeset.change(confirmed_at: now, completed_at: now)
    |> Repo.update!()

    {:ok, _} = Repositories.set_status(genesis.did, :active)
    {:ok, pair} = Sessions.create_for_account(genesis.did)
    {:ok, _} = AppPasswords.create(pair.access_jwt, %{"name" => "old app"})

    directory =
      start_supervised!(
        {Agent,
         fn ->
           %{
             audit: audit,
             last: bad,
             operation: recovery,
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
          assert Jason.decode!(bytes) == state.operation
          Agent.update(directory, &%{&1 | posts: &1.posts + 1})

          if state.reject do
            Plug.Conn.send_resp(conn, 400, "rejected")
          else
            [first | removed] = state.audit

            audit =
              [first | Enum.map(removed, &Map.put(&1, "nullified", true))] ++
                [entry(genesis.did, state.operation, DateTime.utc_now())]

            Agent.update(
              directory,
              &%{&1 | audit: audit, last: state.operation, unavailable: state.ambiguous}
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
      pair: pair,
      high: high,
      opts: [plug: {Req.Test, __MODULE__}, txt_lookup: fn _ -> [["did=" <> genesis.did]] end]
    }
  end

  test "reconciles identity and atomically invalidates credentials, with idempotent retries", c do
    profile = Repo.get!(Profile, c.did)

    profile
    |> Ecto.Changeset.change(
      password_reset_digest: :crypto.strong_rand_bytes(32),
      password_reset_expires_at: System.system_time(:second) + 900,
      password_reset_requested_at: System.system_time(:second),
      plc_signature_digest: :crypto.strong_rand_bytes(32),
      plc_signature_expires_at: System.system_time(:second) + 900,
      plc_signature_requested_at: System.system_time(:second)
    )
    |> Repo.update!()

    seq = Events.latest_seq()
    assert {:ok, %{cid: cid}} = LocalRecovery.stage(c.did, c.recovery, c.opts)
    assert cid == c.cid
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
    assert {:ok, %{result: :completed}} = LocalRecovery.resume(c.did, cid, c.opts)
    assert {:error, _} = Sessions.authenticate(c.pair.access_jwt)
    assert Repo.aggregate(Session, :count) == 0
    assert Repo.aggregate(AppPassword, :count) == 0
    assert Repo.get!(Profile, c.did).password_reset_digest == nil
    assert Repo.get!(Profile, c.did).plc_signature_digest == nil
    assert Repositories.get_head(c.did) == {:ok, c.head}
    assert {:ok, [%{kind: :identity}]} = Events.list_after(seq)
    audit = Repo.one!(Atoll.Moderation.AuditEntry)
    assert audit.operation == "atoll.plc.recover"
    assert audit.after_state["revokedSessions"] == 1
    assert audit.after_state["revokedAppPasswords"] == 1
    assert Repo.get_by!(Update, did: c.did, cid: cid).completed_at
    {:ok, fresh} = Sessions.create_for_account(c.did)
    seq = Events.latest_seq()
    assert {:ok, _} = LocalRecovery.resume(c.did, cid, c.opts)
    assert {:ok, _} = Sessions.authenticate(fresh.access_jwt)
    assert Events.latest_seq() == seq
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 1
    assert Agent.get(c.directory, & &1.posts) == 1
  end

  test "ambiguous delivery retains credentials until verified local completion", c do
    {:ok, _} = LocalRecovery.stage(c.did, c.recovery, c.opts)
    Agent.update(c.directory, &%{&1 | ambiguous: true})
    assert {:error, :plc_unavailable} = LocalRecovery.resume(c.did, c.cid, c.opts)
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
    refute Repo.get_by!(Update, did: c.did, cid: c.cid).completed_at
    Agent.update(c.directory, &%{&1 | unavailable: false})
    assert {:ok, _} = LocalRecovery.resume(c.did, c.cid, c.opts)
    assert {:error, _} = Sessions.authenticate(c.pair.access_jwt)
    assert Agent.get(c.directory, & &1.posts) == 1
  end

  test "wrong local identity or removal of the retained authority never stages", c do
    {:ok, other} = Multikey.to_did_key(:k256, SigningKey.generate().public)

    for unsigned <- [
          Map.put(Map.delete(c.recovery, "sig"), "rotationKeys", [other]),
          Map.put(Map.delete(c.recovery, "sig"), "alsoKnownAs", ["at://other.example.com"])
        ] do
      {:ok, operation} = Operation.sign(unsigned, c.high)
      assert {:error, :invalid_local_recovery} = LocalRecovery.stage(c.did, operation, c.opts)
    end

    assert Repo.aggregate(Update, :count) == 0
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
  end

  test "identity mutation during completion blocks revocation and permits a fresh retry", c do
    {:ok, _} = LocalRecovery.stage(c.did, c.recovery, c.opts)
    calls = :counters.new(1, [])

    opts =
      Keyword.put(c.opts, :txt_lookup, fn _ ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 2 do
          Repo.insert!(%Atoll.Identity.Observation{
            did: c.did,
            handle: "alice.example.com",
            fingerprint: :binary.copy(<<1>>, 32)
          })
        end

        [["did=" <> c.did]]
      end)

    assert {:error, :stale_identity_refresh} = LocalRecovery.resume(c.did, c.cid, opts)
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 0
    assert {:ok, _} = LocalRecovery.resume(c.did, c.cid, c.opts)
  end

  test "suspension blocks submission and deactivation is preserved", c do
    {:ok, _} = LocalRecovery.stage(c.did, c.recovery, c.opts)
    {:ok, _} = Repositories.set_status(c.did, :suspended)
    assert {:error, :repo_inactive} = LocalRecovery.resume(c.did, c.cid, c.opts)
    assert Agent.get(c.directory, & &1.posts) == 0
    {:ok, _} = Repositories.set_status(c.did, :deactivated)
    assert {:ok, _} = LocalRecovery.resume(c.did, c.cid, c.opts)
    assert {:ok, %{status: :deactivated}} = Repositories.get_head(c.did)
  end

  test "replacement-key recovery repairs unreadable custody and publishes identity then sync",
       c do
    new = SigningKey.generate(:p256)
    {op, cid, expected} = key_recovery(c, new)
    {:ok, wrong_expected} = Multikey.to_did_key(new.curve, new.public)

    assert {:error, :stale_signing_key} =
             LocalRecovery.stage_key(c.did, op, wrong_expected, new, c.opts)

    assert {:error, :invalid_key} =
             LocalRecovery.stage_key(
               c.did,
               op,
               expected,
               %{new | public: c.head.public_key},
               c.opts
             )

    assert Repo.aggregate(Update, :count) == 0

    Repo.get!(Atoll.Repositories.EncryptedKey, c.did)
    |> Ecto.Changeset.change(envelope: :binary.copy(<<0>>, 61))
    |> Repo.update!(log: false)

    seq = Events.latest_seq()
    assert {:ok, %{cid: ^cid}} = LocalRecovery.stage_key(c.did, op, expected, new, c.opts)
    assert {:error, :key_decryption_failed} = KeyVault.fetch(c.did)
    assert {:ok, _} = LocalRecovery.resume(c.did, cid, c.opts)
    assert KeyVault.fetch(c.did) == {:ok, new}
    assert {:error, :key_not_found} = Atoll.Identity.PLC.PendingSigningKeys.fetch(c.did, cid)
    assert {:ok, [%{kind: :identity}, %{kind: :sync}]} = Events.list_after(seq)
    {:ok, updated} = Repositories.get_head(c.did)
    assert updated.rev > c.head.rev
    {:ok, bytes} = Atoll.Storage.get_block(updated.head)
    assert {:ok, _} = Atoll.Commit.verify(bytes, c.did, new.curve, new.public)
    audit = Repo.one!(Atoll.Moderation.AuditEntry)
    assert audit.before_state["repositoryKey"] == expected
    {:ok, public} = Multikey.to_did_key(new.curve, new.public)
    assert audit.after_state["repositoryKey"] == public
    {:ok, fresh} = Sessions.create_for_account(c.did)
    assert {:ok, _} = LocalRecovery.resume(c.did, cid, c.opts)
    assert {:ok, _} = Sessions.authenticate(fresh.access_jwt)
    assert Agent.get(c.directory, & &1.posts) == 1
  end

  test "quota rollback preserves credentials, events and pending recovery key", c do
    new = SigningKey.generate(:p256)
    {op, cid, expected} = key_recovery(c, new)
    old = KeyVault.fetch(c.did)
    {:ok, _} = LocalRecovery.stage_key(c.did, op, expected, new, c.opts)
    seq = Events.latest_seq()
    Application.put_env(:atoll, :repository_quota, max_bytes: 0)
    assert {:error, :repository_quota_exceeded} = LocalRecovery.resume(c.did, cid, c.opts)
    assert Events.latest_seq() == seq
    assert KeyVault.fetch(c.did) == old
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
    assert Repo.aggregate(AppPassword, :count) == 1
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 0
    assert {:ok, ^new} = Atoll.Identity.PLC.PendingSigningKeys.fetch(c.did, cid)
    Application.delete_env(:atoll, :repository_quota)
    assert {:ok, _} = LocalRecovery.resume(c.did, cid, c.opts)
    assert Agent.get(c.directory, & &1.posts) == 1
  end

  test "original-key recovery repairs missing vault without a new commit", c do
    {:ok, original} = KeyVault.fetch(c.did)
    {op, cid, expected} = key_recovery(c, original)
    Repo.delete!(Repo.get!(Atoll.Repositories.EncryptedKey, c.did))
    seq = Events.latest_seq()
    assert {:ok, _} = LocalRecovery.stage_key(c.did, op, expected, original, c.opts)
    assert {:ok, _} = LocalRecovery.resume(c.did, cid, c.opts)
    assert KeyVault.fetch(c.did) == {:ok, original}
    assert Repositories.get_head(c.did) == {:ok, c.head}
    assert {:ok, [%{kind: :identity}]} = Events.list_after(seq)
  end

  test "combined recovery restores both keys after losing the old encryption master", c do
    repository = SigningKey.generate(:p256)
    authority = SigningKey.generate()

    {op, cid, expected_repository, expected_authority} =
      combined_recovery(c, repository, authority)

    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    seq = Events.latest_seq()
    assert {:error, :key_decryption_failed} = KeyVault.fetch(c.did)
    assert {:error, :key_decryption_failed} = Registrations.rotation_key(c.did)

    assert {:ok, _} =
             LocalRecovery.stage_keys(
               c.did,
               op,
               {expected_repository, repository},
               {expected_authority, authority},
               c.opts
             )

    row = Repo.get_by!(Update, did: c.did, cid: cid)
    assert row.signing_envelope && row.authority_envelope
    assert {:ok, _} = LocalRecovery.resume(c.did, cid, c.opts)
    assert KeyVault.fetch(c.did) == {:ok, repository}
    assert Registrations.rotation_key(c.did) == {:ok, authority}
    completed = Repo.get_by!(Update, did: c.did, cid: cid)
    assert completed.completed_at
    refute completed.signing_envelope
    refute completed.authority_envelope
    assert {:ok, [%{kind: :identity}, %{kind: :sync}]} = Events.list_after(seq)
    assert {:error, _} = Sessions.authenticate(c.pair.access_jwt)
    audit = Repo.one!(Atoll.Moderation.AuditEntry)
    assert audit.before_state["authorityKey"] == expected_authority
    {:ok, public} = Multikey.to_did_key(authority.curve, authority.public)
    assert audit.after_state["authorityKey"] == public
    {:ok, fresh} = Sessions.create_for_account(c.did)
    assert {:ok, _} = LocalRecovery.resume(c.did, cid, c.opts)
    assert {:ok, _} = Sessions.authenticate(fresh.access_jwt)
    assert Agent.get(c.directory, & &1.posts) == 1
  end

  test "nullified journal reconciliation releases reservations and permits new work", c do
    alias Atoll.Identity.PLC.{NullifiedUpdates, Updates}
    {:ok, cid} = Operation.cid(c.bad)
    assert {:ok, _} = Updates.stage(c.did, c.audit, c.bad)

    reservation =
      Repo.insert!(%Atoll.Identity.HandleReservation{
        did: c.did,
        cid: cid,
        handle: "bad.example.com"
      })

    audit = show_nullification(c, c.bad)
    seq = Events.latest_seq()
    assert {:ok, %{result: :nullified}} = NullifiedUpdates.reconcile(c.did, cid, c.cid, c.opts)
    closed = Repo.get_by!(Update, did: c.did, cid: cid)
    assert closed.nullified_at
    assert closed.nullified_head == c.cid
    refute closed.completed_at
    assert closed.operation == c.bad
    refute Repo.get(Atoll.Identity.HandleReservation, reservation.handle)
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
    assert Events.latest_seq() == seq
    assert {:error, :plc_update_nullified} = Updates.submit(c.did, cid, c.opts)
    assert {:error, :plc_update_nullified} = Updates.stage(c.did, c.audit, c.bad)

    assert {:error, :plc_update_nullified} =
             Repo.transaction(fn -> Updates.complete!(c.did, cid) end)

    assert {:ok, %{result: :already_nullified}} =
             NullifiedUpdates.reconcile(c.did, cid, c.cid, c.opts)

    assert Repo.get_by!(Update, did: c.did, cid: cid).nullified_at == closed.nullified_at
    assert length(Repo.all(Atoll.Moderation.AuditEntry)) == 1
    {:ok, unsigned} = Operation.successor(c.recovery)
    {:ok, next} = Operation.sign(unsigned, c.high)
    assert {:ok, _} = Updates.stage(c.did, audit, next)
    assert Agent.get(c.directory, & &1.posts) == 0
  end

  test "an in-flight submission cannot confirm a journal closed during its directory read", c do
    alias Atoll.Identity.PLC.{NullifiedUpdates, Updates}
    {:ok, cid} = Operation.cid(c.bad)
    assert {:ok, _} = Updates.stage(c.did, c.audit, c.bad)
    audit = show_nullification(c, c.bad)

    Req.Test.stub(:atoll_nullified_evidence, fn conn ->
      if String.ends_with?(conn.request_path, "/log/audit"),
        do: Req.Test.json(conn, audit),
        else: Req.Test.json(conn, c.recovery)
    end)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"

      assert {:ok, _} =
               NullifiedUpdates.reconcile(c.did, cid, c.cid,
                 plug: {Req.Test, :atoll_nullified_evidence}
               )

      Req.Test.json(conn, c.bad)
    end)

    assert {:error, :plc_update_nullified} = Updates.submit(c.did, cid, c.opts)
    closed = Repo.get_by!(Update, did: c.did, cid: cid)
    assert closed.nullified_at
    refute closed.confirmed_at
    refute closed.completed_at
  end

  test "nullified repository-key work releases only pending custody", c do
    {cid, key} = stage_nullified_key(c, :repository)
    assert {:ok, ^key} = Atoll.Identity.PLC.PendingSigningKeys.fetch(c.did, cid)
    assert {:ok, _} = Atoll.Identity.PLC.NullifiedUpdates.reconcile(c.did, cid, c.cid, c.opts)
    closed = Repo.get_by!(Update, did: c.did, cid: cid)
    assert closed.signing_public_key == key.public
    refute closed.signing_envelope
    assert {:ok, %{result: :no_pending_rotation}} = Atoll.Identity.PLC.KeyRotation.status(c.did)
    assert {:error, _} = Atoll.Identity.PLC.KeyRotation.resume(c.did, cid, c.opts)
    assert Repositories.get_head(c.did) == {:ok, c.head}
    assert {:ok, old} = KeyVault.fetch(c.did)
    assert old.public == c.head.public_key
  end

  test "nullified authority work releases custody through the operator CLI", c do
    {cid, key} = stage_nullified_key(c, :authority)
    assert {:ok, ^key} = Atoll.Identity.PLC.PendingAuthorityKeys.fetch(c.did, cid)
    Application.put_env(:atoll, :plc_submission_options, Keyword.take(c.opts, [:plug]))

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Plc.ReconcileNullified.run([c.did, cid, c.cid])
      end)

    assert Jason.decode!(output)["result"] == "nullified"
    refute Repo.get_by!(Update, did: c.did, cid: cid).authority_envelope

    assert {:ok, %{result: :no_pending_rotation}} =
             Atoll.Identity.PLC.AuthorityRotation.status(c.did)

    assert {:error, _} = Atoll.Identity.PLC.AuthorityRotation.resume(c.did, cid, c.opts)
    assert Registrations.rotation_key(c.did) == {:ok, c.high}
  end

  test "nullification reconciliation rejects active, missing, stale-head, and completed work",
       c do
    alias Atoll.Identity.PLC.{NullifiedUpdates, Updates}
    {:ok, cid} = Operation.cid(c.bad)
    assert {:ok, _} = Updates.stage(c.did, c.audit, c.bad)
    assert {:error, :plc_conflict} = NullifiedUpdates.reconcile(c.did, cid, cid, c.opts)
    assert {:error, :plc_conflict} = NullifiedUpdates.reconcile(c.did, c.cid, cid, c.opts)
    show_nullification(c, c.bad)
    assert {:error, :plc_conflict} = NullifiedUpdates.reconcile(c.did, cid, cid, c.opts)
    row = Repo.get_by!(Update, did: c.did, cid: cid)
    refute row.nullified_at
    row |> Ecto.Changeset.change(confirmed_at: c.now, completed_at: c.now) |> Repo.update!()
    assert {:error, :plc_update_completed} = NullifiedUpdates.reconcile(c.did, cid, c.cid, c.opts)
    assert Repo.all(Atoll.Moderation.AuditEntry) == []
    assert Agent.get(c.directory, & &1.posts) == 0
  end

  test "recovery installs authority when local metadata is absent and binds absence to custody",
       c do
    Repo.delete!(Repo.get!(Atoll.Identity.PLC.Registration, c.did))
    assert {:ok, _} = LocalRecovery.stage_authority(c.did, c.recovery, :absent, c.high, c.opts)
    row = Repo.get_by!(Update, did: c.did, cid: c.cid)
    assert row.authority_public_key == c.high.public
    assert is_nil(row.expected_authority_key)
    assert {:ok, key} = Atoll.Identity.PLC.PendingAuthorityKeys.fetch(c.did, c.cid)
    assert key == c.high
    assert {:ok, _} = LocalRecovery.stage_authority(c.did, c.recovery, :absent, c.high, c.opts)

    assert Repo.get_by!(Update, did: c.did, cid: c.cid).authority_envelope ==
             row.authority_envelope

    {:ok, public} = Multikey.to_did_key(c.high.curve, c.high.public)
    row |> Ecto.Changeset.change(expected_authority_key: public) |> Repo.update!()

    assert {:error, :key_decryption_failed} =
             Atoll.Identity.PLC.PendingAuthorityKeys.fetch(c.did, c.cid)

    Repo.get_by!(Update, did: c.did, cid: c.cid)
    |> Ecto.Changeset.change(expected_authority_key: nil)
    |> Repo.update!()

    assert {:ok, _} = LocalRecovery.resume(c.did, c.cid, c.opts)
    assert Registrations.rotation_key(c.did) == {:ok, c.high}
    audit = Repo.one!(Atoll.Moderation.AuditEntry)
    assert audit.before_state["authorityWasAbsent"]
    assert audit.before_state["authorityKey"] == nil
    assert audit.after_state["authorityKey"] == public
    assert {:ok, _} = LocalRecovery.resume(c.did, c.cid, c.opts)
    assert Agent.get(c.directory, & &1.posts) == 1
    assert {:ok, %{unchanged: 2}} = Atoll.KeyRewrap.batch()
  end

  test "combined recovery restores missing repository custody and absent authority metadata", c do
    repository = SigningKey.generate(:p256)
    authority = SigningKey.generate()
    {op, cid, expected_repository, _} = combined_recovery(c, repository, authority)
    Repo.delete!(Repo.get!(Atoll.Identity.PLC.Registration, c.did))
    Repo.delete!(Repo.get!(Atoll.Repositories.EncryptedKey, c.did))
    seq = Events.latest_seq()

    assert {:ok, _} =
             LocalRecovery.stage_keys(
               c.did,
               op,
               {expected_repository, repository},
               {:absent, authority},
               c.opts
             )

    assert {:ok, _} = LocalRecovery.resume(c.did, cid, c.opts)
    assert KeyVault.fetch(c.did) == {:ok, repository}
    assert Registrations.rotation_key(c.did) == {:ok, authority}
    assert {:ok, [%{kind: :identity}, %{kind: :sync}]} = Events.list_after(seq)
  end

  test "absent authority expectation rejects existing metadata and ordinary rotation", c do
    assert {:error, :stale_rotation_key} =
             LocalRecovery.stage_authority(c.did, c.recovery, :absent, c.high, c.opts)

    assert {:error, :invalid_key} =
             Atoll.Identity.PLC.PendingAuthorityKeys.stage(
               c.did,
               c.audit,
               c.recovery,
               :absent,
               c.high
             )

    assert Repo.all(Update) == []
    assert Agent.get(c.directory, & &1.posts) == 0
  end

  test "authority metadata appearing after staging blocks recovery before POST", c do
    original = Repo.get!(Atoll.Identity.PLC.Registration, c.did)
    Repo.delete!(original)
    assert {:ok, _} = LocalRecovery.stage_authority(c.did, c.recovery, :absent, c.high, c.opts)
    Repo.insert!(Ecto.reset_fields(original, [:__meta__]))
    assert {:error, :stale_rotation_key} = LocalRecovery.resume(c.did, c.cid, c.opts)
    assert Agent.get(c.directory, & &1.posts) == 0
    assert {:ok, _} = Atoll.Identity.PLC.PendingAuthorityKeys.fetch(c.did, c.cid)
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
  end

  test "authority recovery CLI accepts explicit absent metadata", c do
    Repo.delete!(Repo.get!(Atoll.Identity.PLC.Registration, c.did))
    base = Path.join(System.tmp_dir!(), "atoll-absent-#{System.unique_integer([:positive])}")
    op_path = base <> ".op.json"
    key_path = base <> ".key.json"
    on_exit(fn -> Enum.each([op_path, key_path], &File.rm/1) end)
    File.write!(op_path, Jason.encode!(c.recovery))

    File.write!(
      key_path,
      Jason.encode!(%{curve: "p256", privateKey: Base.encode64(c.high.private)})
    )

    File.chmod!(key_path, 0o600)
    Application.put_env(:atoll, :identity_resolution_options, Keyword.drop(c.opts, [:plug]))
    Application.put_env(:atoll, :plc_submission_options, Keyword.take(c.opts, [:plug]))

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Plc.Recover.run(["stage-authority", c.did, op_path, key_path, "absent"])
      end)

    assert Jason.decode!(output)["cid"] == c.cid
    refute output =~ Base.encode64(c.high.private)
    File.rm!(key_path)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Plc.Recover.run(["resume", c.did, c.cid])
      end)

    assert Jason.decode!(output)["result"] == "completed"
    assert Registrations.rotation_key(c.did) == {:ok, c.high}
  end

  test "explicit signup retirement unblocks rewrap after lost-master recovery", c do
    repository = SigningKey.generate(:p256)
    authority = SigningKey.generate()

    {op, cid, expected_repository, expected_authority} =
      combined_recovery(c, repository, authority)

    original = Repo.get!(Atoll.Identity.PLC.Registration, c.did)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))

    assert {:ok, _} =
             LocalRecovery.stage_keys(
               c.did,
               op,
               {expected_repository, repository},
               {expected_authority, authority},
               c.opts
             )

    assert {:ok, _} = LocalRecovery.resume(c.did, cid, c.opts)
    assert {:error, :key_decryption_failed} = Atoll.KeyRewrap.batch()
    {:ok, public} = Multikey.to_did_key(authority.curve, authority.public)
    seq = Events.latest_seq()

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Plc.RetireSignupKey.run([c.did, original.cid, public])
      end)

    assert Jason.decode!(output)["result"] == "retired"
    retired = Repo.get!(Atoll.Identity.PLC.Registration, c.did)
    assert retired.rotation_retired_at
    refute retired.rotation_envelope
    assert retired.operation == original.operation
    assert retired.rotation_public_key == original.rotation_public_key
    assert {:ok, %{unchanged: 2}} = Atoll.KeyRewrap.batch()
    assert {:ok, ^authority} = Registrations.rotation_key(c.did)
    assert Events.latest_seq() == seq

    assert {:ok, %{result: :already_retired}} =
             Atoll.Identity.PLC.SignupKeyRetirement.retire(c.did, original.cid, public)

    assert Repo.get!(Atoll.Identity.PLC.Registration, c.did).rotation_retired_at ==
             retired.rotation_retired_at

    audits = Repo.all(Atoll.Moderation.AuditEntry)
    assert length(audits) == 2
    audit = Enum.find(audits, &(&1.operation == "atoll.plc.retireSignupKey"))
    assert audit.before_state["retained"]
    refute audit.after_state["retained"]
  end

  test "signup retirement refuses missing installed custody, pending work, and stale expectations",
       c do
    registration = Repo.get!(Atoll.Identity.PLC.Registration, c.did)
    {:ok, public} = Multikey.to_did_key(c.high.curve, c.high.public)

    retire = fn genesis, key ->
      Atoll.Identity.PLC.SignupKeyRetirement.retire(c.did, genesis, key)
    end

    assert {:error, :key_not_found} = retire.(registration.cid, public)
    assert {:ok, _} = LocalRecovery.stage_authority(c.did, c.recovery, public, c.high, c.opts)
    assert {:error, :plc_update_pending} = retire.(registration.cid, public)
    assert {:ok, _} = LocalRecovery.resume(c.did, c.cid, c.opts)
    assert {:error, :signup_retirement_conflict} = retire.("wrong", public)
    assert {:error, :stale_rotation_key} = retire.(registration.cid, "wrong")

    assert Repo.get!(Atoll.Identity.PLC.Registration, c.did).rotation_envelope ==
             registration.rotation_envelope

    installed = Repo.get!(Atoll.Identity.PLC.RotationKey, c.did)

    installed
    |> Ecto.Changeset.change(envelope: :binary.copy(<<0>>, 61))
    |> Repo.update!(log: false)

    assert {:error, :key_decryption_failed} = retire.(registration.cid, public)
    refute Repo.get!(Atoll.Identity.PLC.Registration, c.did).rotation_retired_at
  end

  test "signup retirement requires completed signup and readable repository custody", c do
    registration = Repo.get!(Atoll.Identity.PLC.Registration, c.did)
    {:ok, public} = Multikey.to_did_key(c.high.curve, c.high.public)
    registration |> Ecto.Changeset.change(completed_at: nil) |> Repo.update!()

    assert {:error, :signup_retirement_conflict} =
             Atoll.Identity.PLC.SignupKeyRetirement.retire(c.did, registration.cid, public)

    Repo.get!(Atoll.Identity.PLC.Registration, c.did)
    |> Ecto.Changeset.change(completed_at: registration.completed_at)
    |> Repo.update!()

    assert {:ok, _} = LocalRecovery.stage_authority(c.did, c.recovery, public, c.high, c.opts)
    assert {:ok, _} = LocalRecovery.resume(c.did, c.cid, c.opts)

    Repo.get!(Atoll.Repositories.EncryptedKey, c.did)
    |> Ecto.Changeset.change(envelope: :binary.copy(<<0>>, 61))
    |> Repo.update!(log: false)

    assert {:error, :key_decryption_failed} =
             Atoll.Identity.PLC.SignupKeyRetirement.retire(c.did, registration.cid, public)

    refute Repo.get!(Atoll.Identity.PLC.Registration, c.did).rotation_retired_at
  end

  test "signup retirement and audit roll back with the surrounding transaction", c do
    registration = Repo.get!(Atoll.Identity.PLC.Registration, c.did)
    {:ok, public} = Multikey.to_did_key(c.high.curve, c.high.public)
    assert {:ok, _} = LocalRecovery.stage_authority(c.did, c.recovery, public, c.high, c.opts)
    assert {:ok, _} = LocalRecovery.resume(c.did, c.cid, c.opts)

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        Atoll.Identity.PLC.SignupKeyRetirement.retire(
                          c.did,
                          registration.cid,
                          public
                        )

               Repo.rollback(:abort)
             end)

    assert Repo.get!(Atoll.Identity.PLC.Registration, c.did).rotation_envelope ==
             registration.rotation_envelope

    assert length(Repo.all(Atoll.Moderation.AuditEntry)) == 1
  end

  test "combined recovery rollback restores old authority and keeps both pending keys", c do
    repository = SigningKey.generate(:p256)
    authority = SigningKey.generate()

    {op, cid, expected_repository, expected_authority} =
      combined_recovery(c, repository, authority)

    assert {:ok, _} =
             LocalRecovery.stage_keys(
               c.did,
               op,
               {expected_repository, repository},
               {expected_authority, authority},
               c.opts
             )

    Application.put_env(:atoll, :repository_quota, max_bytes: 0)
    seq = Events.latest_seq()
    assert {:error, :repository_quota_exceeded} = LocalRecovery.resume(c.did, cid, c.opts)
    assert Registrations.rotation_key(c.did) == {:ok, c.high}
    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
    assert Events.latest_seq() == seq
    assert {:ok, ^repository} = Atoll.Identity.PLC.PendingSigningKeys.fetch(c.did, cid)
    assert {:ok, ^authority} = Atoll.Identity.PLC.PendingAuthorityKeys.fetch(c.did, cid)
    Application.delete_env(:atoll, :repository_quota)
    assert {:ok, _} = LocalRecovery.resume(c.did, cid, c.opts)
    assert Agent.get(c.directory, & &1.posts) == 1
  end

  test "authority-only recovery repairs custody and leaves repository commit unchanged", c do
    {:ok, repository} = KeyVault.fetch(c.did)
    {op, cid, _, expected_authority} = combined_recovery(c, repository, c.high)

    Repo.get!(Atoll.Identity.PLC.Registration, c.did)
    |> Ecto.Changeset.change(rotation_envelope: :binary.copy(<<0>>, 61))
    |> Repo.update!(log: false)

    seq = Events.latest_seq()
    assert {:ok, _} = LocalRecovery.stage_authority(c.did, op, expected_authority, c.high, c.opts)
    assert {:ok, _} = LocalRecovery.resume(c.did, cid, c.opts)
    assert Registrations.rotation_key(c.did) == {:ok, c.high}
    assert Repositories.get_head(c.did) == {:ok, c.head}
    assert {:ok, [%{kind: :identity}]} = Events.list_after(seq)
  end

  test "combined CLI staging resumes after both private files are removed", c do
    repository = SigningKey.generate(:p256)
    authority = SigningKey.generate()

    {op, cid, expected_repository, expected_authority} =
      combined_recovery(c, repository, authority)

    base = Path.join(System.tmp_dir!(), "atoll-combined-#{System.unique_integer([:positive])}")
    paths = Enum.map(["op", "repository", "authority"], &(base <> "." <> &1 <> ".json"))
    [op_path, repository_path, authority_path] = paths
    on_exit(fn -> Enum.each(paths, &File.rm/1) end)
    File.write!(op_path, Jason.encode!(op))

    for {path, key} <- [{repository_path, repository}, {authority_path, authority}] do
      File.write!(
        path,
        Jason.encode!(%{curve: Atom.to_string(key.curve), privateKey: Base.encode64(key.private)})
      )

      File.chmod!(path, 0o600)
    end

    Application.put_env(:atoll, :identity_resolution_options, Keyword.drop(c.opts, [:plug]))
    Application.put_env(:atoll, :plc_submission_options, Keyword.take(c.opts, [:plug]))

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Plc.Recover.run([
          "stage-keys",
          c.did,
          op_path,
          repository_path,
          expected_repository,
          authority_path,
          expected_authority
        ])
      end)

    assert Jason.decode!(output)["cid"] == cid
    refute output =~ Base.encode64(repository.private)
    refute output =~ Base.encode64(authority.private)
    File.rm!(repository_path)
    File.rm!(authority_path)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Plc.Recover.run(["resume", c.did, cid])
      end)

    assert Jason.decode!(output)["result"] == "completed"
    assert KeyVault.fetch(c.did) == {:ok, repository}
    assert Registrations.rotation_key(c.did) == {:ok, authority}
  end

  test "stage-key CLI bounds and redacts private input", c do
    new = SigningKey.generate(:p256)
    {op, cid, expected} = key_recovery(c, new)

    base =
      Path.join(System.tmp_dir!(), "atoll-recovery-key-#{System.unique_integer([:positive])}")

    op_path = base <> ".operation.json"
    key_path = base <> ".key.json"

    on_exit(fn ->
      File.rm(op_path)
      File.rm(key_path)
    end)

    File.write!(op_path, Jason.encode!(op))
    File.write!(key_path, Jason.encode!(%{curve: "p256", privateKey: Base.encode64(new.private)}))
    File.chmod!(key_path, 0o600)
    Application.put_env(:atoll, :identity_resolution_options, Keyword.drop(c.opts, [:plug]))
    Application.put_env(:atoll, :plc_submission_options, Keyword.take(c.opts, [:plug]))

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Plc.Recover.run(["stage-key", c.did, op_path, key_path, expected])
      end)

    assert Jason.decode!(output)["cid"] == cid
    refute output =~ Base.encode64(new.private)
    File.rm!(key_path)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Plc.Recover.run(["resume", c.did, cid])
      end)

    assert Jason.decode!(output)["result"] == "completed"
    assert KeyVault.fetch(c.did) == {:ok, new}
    File.write!(key_path, String.duplicate("x", 4097))

    assert_raise Mix.Error, ~r/Invalid or unreadable recovery private-key file/, fn ->
      Mix.Tasks.Atoll.Plc.Recover.run(["stage-key", c.did, op_path, key_path, expected])
    end
  end

  test "CLI reads bounded unique-key JSON and prints public journal state", c do
    path =
      Path.join(System.tmp_dir!(), "atoll-recovery-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)
    File.write!(path, Jason.encode!(c.recovery))
    Application.put_env(:atoll, :identity_resolution_options, Keyword.drop(c.opts, [:plug]))
    Application.put_env(:atoll, :plc_submission_options, Keyword.take(c.opts, [:plug]))

    result =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Plc.Recover.run(["stage", c.did, path])
      end)
      |> Jason.decode!()

    assert result["cid"] == c.cid

    output =
      ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Atoll.Plc.Recover.run(["status", c.did]) end)
      |> Jason.decode!()

    assert output["confirmed"] == false

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Plc.Recover.run(["resume", c.did, c.cid])
      end)
      |> Jason.decode!()

    assert output["result"] == "completed"

    for invalid <- [String.duplicate("x", 65_537), "{\"type\":1,\"type\":2}"] do
      File.write!(path, invalid)

      assert_raise Mix.Error, ~r/Invalid or unreadable signed recovery file/, fn ->
        Mix.Tasks.Atoll.Plc.Recover.run(["stage", c.did, path])
      end
    end
  end

  test "accepted recovery reconciles after compatible advancement without reposting or repeated revocation",
       c do
    {:ok, %{cid: cid}} = LocalRecovery.stage(c.did, c.recovery, c.opts)

    expected =
      advance_recovery(
        c,
        c.recovery,
        c.high,
        &put_in(&1, ["services", "extra"], %{
          "type" => "ExampleService",
          "endpoint" => "https://extra.example.com"
        })
      )

    seq = Events.latest_seq()
    assert {:ok, %{result: :completed}} = LocalRecovery.reconcile(c.did, cid, expected, c.opts)
    assert {:error, _} = Sessions.authenticate(c.pair.access_jwt)
    assert Repo.aggregate(AppPassword, :count) == 0
    assert Repositories.get_head(c.did) == {:ok, c.head}
    assert {:ok, [%{kind: :identity}]} = Events.list_after(seq)
    row = Repo.get_by!(Update, did: c.did, cid: cid)
    assert row.confirmed_at && row.completed_at
    audit = Repo.one!(Atoll.Moderation.AuditEntry)
    assert audit.operation == "atoll.plc.reconcileRecovery"
    assert audit.requested["observedHead"] == expected
    {:ok, fresh} = Sessions.create_for_account(c.did)
    seq = Events.latest_seq()
    assert {:ok, _} = LocalRecovery.reconcile(c.did, cid, expected, c.opts)
    assert {:ok, _} = Sessions.authenticate(fresh.access_jwt)
    assert Events.latest_seq() == seq
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 1
    assert Agent.get(c.directory, & &1.posts) == 0
  end

  test "combined recovery reconciliation preserves custody and credentials on quota rollback",
       c do
    repository = SigningKey.generate(:p256)
    authority = SigningKey.generate()

    {op, cid, expected_repository, expected_authority} =
      combined_recovery(c, repository, authority)

    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))

    assert {:ok, _} =
             LocalRecovery.stage_keys(
               c.did,
               op,
               {expected_repository, repository},
               {expected_authority, authority},
               c.opts
             )

    expected = advance_recovery(c, op, authority, & &1)
    seq = Events.latest_seq()
    Application.put_env(:atoll, :repository_quota, max_bytes: 0)

    assert {:error, :repository_quota_exceeded} =
             LocalRecovery.reconcile(c.did, cid, expected, c.opts)

    assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
    assert Events.latest_seq() == seq
    row = Repo.get_by!(Update, did: c.did, cid: cid)
    assert row.signing_envelope && row.authority_envelope
    assert is_nil(row.confirmed_at) && is_nil(row.completed_at)
    Application.delete_env(:atoll, :repository_quota)
    assert {:ok, _} = LocalRecovery.reconcile(c.did, cid, expected, c.opts)
    assert KeyVault.fetch(c.did) == {:ok, repository}
    assert Registrations.rotation_key(c.did) == {:ok, authority}
    row = Repo.get_by!(Update, did: c.did, cid: cid)
    refute row.signing_envelope || row.authority_envelope
    assert {:error, _} = Sessions.authenticate(c.pair.access_jwt)
    assert {:ok, [%{kind: :identity}, %{kind: :sync}]} = Events.list_after(seq)
    assert Agent.get(c.directory, & &1.posts) == 0
  end

  test "reviewed recovery scope and deadline must match historical acceptance", c do
    {:ok, %{cid: cid}} = LocalRecovery.stage(c.did, c.recovery, c.opts)
    expected = advance_recovery(c, c.recovery, c.high, & &1)
    row = Repo.get_by!(Update, did: c.did, cid: cid)

    for changes <- [
          [recovery_expected_head: hd(c.audit)["cid"]],
          [recovery_deadline: DateTime.add(row.recovery_deadline, -1, :second)],
          [recovery_nullified_cids: [hd(c.audit)["cid"]]]
        ] do
      Repo.get_by!(Update, did: c.did, cid: cid)
      |> Ecto.Changeset.change(changes)
      |> Repo.update!()

      assert {:error, _} = LocalRecovery.reconcile(c.did, cid, expected, c.opts)

      Repo.get_by!(Update, did: c.did, cid: cid)
      |> Ecto.Changeset.change(
        recovery_expected_head: row.recovery_expected_head,
        recovery_deadline: row.recovery_deadline,
        recovery_nullified_cids: row.recovery_nullified_cids
      )
      |> Repo.update!()

      assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
      assert is_nil(Repo.get_by!(Update, did: c.did, cid: cid).confirmed_at)
    end

    assert {:error, _} = LocalRecovery.reconcile(c.did, cid, cid, c.opts)
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 0
  end

  test "incompatible current recovery identity leaves credentials and pending journal unchanged",
       c do
    {:ok, %{cid: cid}} = LocalRecovery.stage(c.did, c.recovery, c.opts)

    for change <- [
          &Map.put(&1, "alsoKnownAs", ["at://other.example.com"]),
          &put_in(&1, ["services", "atproto_pds", "endpoint"], "https://other.example.com"),
          &Map.put(&1, "rotationKeys", c.bad["rotationKeys"])
        ] do
      expected = advance_recovery(c, c.recovery, c.high, change)
      assert {:error, _} = LocalRecovery.reconcile(c.did, cid, expected, c.opts)
      assert {:ok, _} = Sessions.authenticate(c.pair.access_jwt)
      assert is_nil(Repo.get_by!(Update, did: c.did, cid: cid).confirmed_at)
    end

    assert Agent.get(c.directory, & &1.posts) == 0
  end

  defp advance_recovery(c, operation, signer, change) do
    {:ok, unsigned} = Operation.successor(operation)
    {:ok, advanced} = Operation.sign(change.(unsigned), signer)
    now = DateTime.utc_now()

    audit = [
      hd(c.audit),
      Map.put(List.last(c.audit), "nullified", true),
      entry(c.did, operation, now),
      entry(c.did, advanced, DateTime.add(now, 1, :second))
    ]

    Agent.update(c.directory, &%{&1 | audit: audit, last: advanced})
    {:ok, cid} = Operation.cid(advanced)
    cid
  end

  defp show_nullification(c, operation) do
    audit = [
      hd(c.audit),
      Map.put(entry(c.did, operation, DateTime.add(c.now, -30, :second)), "nullified", true),
      entry(c.did, c.recovery, c.now)
    ]

    Agent.update(c.directory, &%{&1 | audit: audit, last: c.recovery})
    audit
  end

  defp stage_nullified_key(c, purpose) do
    genesis = hd(c.audit)["operation"]
    replacement = SigningKey.generate(:p256)
    {:ok, public} = Multikey.to_did_key(replacement.curve, replacement.public)
    {:ok, unsigned} = Operation.successor(genesis)

    {unsigned, expected, module} =
      case purpose do
        :repository ->
          {put_in(unsigned, ["verificationMethods", "atproto"], public),
           genesis["verificationMethods"]["atproto"], Atoll.Identity.PLC.PendingSigningKeys}

        :authority ->
          [old | rest] = unsigned["rotationKeys"]

          {Map.put(unsigned, "rotationKeys", [public | rest]), old,
           Atoll.Identity.PLC.PendingAuthorityKeys}
      end

    {:ok, operation} = Operation.sign(unsigned, c.low)
    {:ok, cid} = Operation.cid(operation)
    assert {:ok, _} = module.stage(c.did, [hd(c.audit)], operation, expected, replacement)
    show_nullification(c, operation)
    {cid, replacement}
  end

  defp combined_recovery(c, repository, authority) do
    {:ok, public} = Multikey.to_did_key(repository.curve, repository.public)
    {:ok, authority_public} = Multikey.to_did_key(authority.curve, authority.public)
    {:ok, expected_repository} = Multikey.to_did_key(c.head.curve, c.head.public_key)
    {:ok, expected_authority} = Atoll.Identity.PLC.RotationKeys.public_key(c.did)

    {:ok, op} =
      c.recovery
      |> Map.delete("sig")
      |> put_in(["verificationMethods", "atproto"], public)
      |> Map.put("rotationKeys", [authority_public])
      |> Operation.sign(c.high)

    {:ok, cid} = Operation.cid(op)
    Agent.update(c.directory, &%{&1 | operation: op})
    {op, cid, expected_repository, expected_authority}
  end

  defp key_recovery(c, key) do
    {:ok, public} = Multikey.to_did_key(key.curve, key.public)
    {:ok, expected} = Multikey.to_did_key(c.head.curve, c.head.public_key)

    {:ok, op} =
      c.recovery
      |> Map.delete("sig")
      |> put_in(["verificationMethods", "atproto"], public)
      |> Operation.sign(c.high)

    {:ok, cid} = Operation.cid(op)
    Agent.update(c.directory, &%{&1 | operation: op})
    {op, cid, expected}
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
