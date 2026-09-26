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
          :plc_submission_options
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
