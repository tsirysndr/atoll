defmodule Atoll.PLCKeyRotationTest do
  use Atoll.DataCase, async: false
  alias Atoll.{KeyVault, Multikey, Repositories, SigningKey}
  alias Atoll.Accounts.Profile
  alias Atoll.Identity.PLC.{KeyRotation, Operation, PendingSigningKeys, Registrations, Update}
  alias Atoll.Repositories.Events

  setup do
    for name <- [
          :key_encryption_key,
          :repository_quota,
          :identity_resolution_options,
          :plc_submission_options
        ] do
      previous = Application.fetch_env(:atoll, name)

      on_exit(fn ->
        case previous do
          {:ok, val} -> Application.put_env(:atoll, name, val)
          :error -> Application.delete_env(:atoll, name)
        end
      end)
    end

    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "https", host: "pds.example.com", port: 443)}
      ],
      []
    )

    on_exit(fn -> AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], []) end)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    old = SigningKey.generate()
    rotation = SigningKey.generate()
    {:ok, expected} = Multikey.to_did_key(old.curve, old.public)
    {:ok, rotating} = Multikey.to_did_key(rotation.curve, rotation.public)

    {:ok, genesis} =
      Operation.create_atproto(
        expected,
        "alice.example.com",
        AtollWeb.Endpoint.url(),
        [rotating],
        rotation
      )

    {:ok, head} = Repositories.create(genesis.did, old)
    {:ok, _} = KeyVault.store(genesis.did, old)
    Repo.insert!(%Profile{did: genesis.did, handle: "alice.example.com"})
    {:ok, _} = Repositories.set_status(genesis.did, :deactivated)
    {:ok, _} = Registrations.stage(genesis.did, genesis.operation, rotation)
    {:ok, _} = Repositories.set_status(genesis.did, :active)

    audit = [
      %{
        "did" => genesis.did,
        "cid" => genesis.cid,
        "operation" => genesis.operation,
        "nullified" => false,
        "createdAt" => "2026-01-01T00:00:00Z"
      }
    ]

    directory =
      start_supervised!(
        {Agent,
         fn ->
           %{
             audit: audit,
             last: genesis.operation,
             posts: 0,
             unavailable: false,
             ambiguous: false
           }
         end}
      )

    Req.Test.stub(__MODULE__, fn conn ->
      state = Agent.get(directory, & &1)

      cond do
        state.unavailable ->
          Req.Test.transport_error(conn, :timeout)

        conn.method == "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          op = Jason.decode!(body)
          assert {:ok, _} = Operation.verify_update(state.last, op)
          {:ok, cid} = Operation.cid(op)

          entry = %{
            "did" => genesis.did,
            "cid" => cid,
            "operation" => op,
            "nullified" => false,
            "createdAt" => "2026-01-02T00:00:00Z"
          }

          Agent.update(
            directory,
            &%{
              &1
              | audit: &1.audit ++ [entry],
                last: op,
                posts: &1.posts + 1,
                unavailable: state.ambiguous
            }
          )

          if state.ambiguous,
            do: Req.Test.transport_error(conn, :timeout),
            else: Req.Test.json(conn, %{})

        String.ends_with?(conn.request_path, "/log/audit") ->
          Req.Test.json(conn, state.audit)

        true ->
          Req.Test.json(conn, state.last)
      end
    end)

    opts = [plug: {Req.Test, __MODULE__}, txt_lookup: fn _ -> [["did=" <> genesis.did]] end]

    %{
      did: genesis.did,
      expected: expected,
      old: old,
      head: head,
      rotation: rotation,
      directory: directory,
      opts: opts
    }
  end

  test "stage preserves identity fields and resume publishes once with an audit", c do
    seq = Events.latest_seq()

    assert {:ok, %{cid: cid, result: :staged}} =
             KeyRotation.stage(c.did, c.expected, :p256, c.opts)

    row = Repo.get_by!(Update, did: c.did, cid: cid)
    assert {:ok, successor} = Operation.successor(row.previous)

    assert Map.drop(row.operation, ["sig", "verificationMethods"]) ==
             Map.delete(successor, "verificationMethods")

    assert KeyVault.fetch(c.did) == {:ok, c.old}
    assert Events.latest_seq() == seq
    assert {:ok, key} = PendingSigningKeys.fetch(c.did, cid)
    assert {:ok, %{result: :completed}} = KeyRotation.resume(c.did, cid, c.opts)
    assert KeyVault.fetch(c.did) == {:ok, key}
    assert {:error, :key_not_found} = PendingSigningKeys.fetch(c.did, cid)
    assert {:ok, [%{kind: :identity}, %{kind: :sync}]} = Events.list_after(seq)
    assert Repo.one!(Atoll.Moderation.AuditEntry).operation == "atoll.keys.rotatePlc"
    seq = Events.latest_seq()
    assert {:ok, %{result: :completed}} = KeyRotation.resume(c.did, cid, c.opts)
    assert Events.latest_seq() == seq
    assert Agent.get(c.directory, & &1.posts) == 1
  end

  test "ambiguous acceptance resumes the same encrypted key without reposting", c do
    {:ok, %{cid: cid}} = KeyRotation.stage(c.did, c.expected, :p256, c.opts)
    {:ok, key} = PendingSigningKeys.fetch(c.did, cid)
    Agent.update(c.directory, &%{&1 | ambiguous: true})
    assert {:error, :plc_unavailable} = KeyRotation.resume(c.did, cid, c.opts)
    assert PendingSigningKeys.fetch(c.did, cid) == {:ok, key}
    assert KeyVault.fetch(c.did) == {:ok, c.old}
    Agent.update(c.directory, &%{&1 | unavailable: false})
    assert {:ok, _} = KeyRotation.resume(c.did, cid, c.opts)
    assert KeyVault.fetch(c.did) == {:ok, key}
    assert Agent.get(c.directory, & &1.posts) == 1
  end

  test "failed local publication retains confirmed custody for retry", c do
    {:ok, %{cid: cid}} = KeyRotation.stage(c.did, c.expected, :p256, c.opts)
    seq = Events.latest_seq()
    Application.put_env(:atoll, :repository_quota, max_bytes: 0)
    assert {:error, :repository_quota_exceeded} = KeyRotation.resume(c.did, cid, c.opts)
    assert Events.latest_seq() == seq
    assert KeyVault.fetch(c.did) == {:ok, c.old}
    row = Repo.get_by!(Update, did: c.did, cid: cid)
    assert row.confirmed_at
    refute row.completed_at
    assert row.signing_envelope
    Application.delete_env(:atoll, :repository_quota)
    assert {:ok, _} = KeyRotation.resume(c.did, cid, c.opts)
    assert Agent.get(c.directory, & &1.posts) == 1
  end

  test "stale keys and conflicting pending work reject staging", c do
    {:ok, wrong} = Multikey.to_did_key(:k256, SigningKey.generate().public)
    assert {:error, _} = KeyRotation.stage(c.did, wrong, :p256, c.opts)
    assert Repo.aggregate(Update, :count) == 0
    {:ok, %{cid: cid}} = KeyRotation.stage(c.did, c.expected, :p256, c.opts)
    assert {:error, :plc_update_pending} = KeyRotation.stage(c.did, c.expected, :p256, c.opts)
    assert Repo.get_by!(Update, did: c.did, cid: cid).signing_envelope

    Repo.get!(Profile, c.did)
    |> Ecto.Changeset.change(handle: "other.example.com")
    |> Repo.update!()

    assert {:error, :invalid_key_rotation} = KeyRotation.resume(c.did, cid, c.opts)
    assert Agent.get(c.directory, & &1.posts) == 0
  end

  test "missing rotation authority leaves no pending key or operation", c do
    Repo.delete!(Repo.get!(Atoll.Identity.PLC.Registration, c.did))
    assert {:error, :registration_not_found} = KeyRotation.stage(c.did, c.expected, :p256, c.opts)
    assert Repo.aggregate(Update, :count) == 0
    assert Agent.get(c.directory, & &1.posts) == 0
  end

  test "suspension blocks submission and deactivation is preserved on completion", c do
    {:ok, %{cid: cid}} = KeyRotation.stage(c.did, c.expected, :p256, c.opts)
    {:ok, _} = Repositories.set_status(c.did, :suspended)
    assert {:error, :repo_inactive} = KeyRotation.resume(c.did, cid, c.opts)
    assert Agent.get(c.directory, & &1.posts) == 0
    {:ok, _} = Repositories.set_status(c.did, :deactivated)
    assert {:ok, _} = KeyRotation.resume(c.did, cid, c.opts)
    assert {:ok, %{status: :deactivated}} = Repositories.get_head(c.did)
  end

  test "a later directory operation cannot complete an earlier confirmed rotation", c do
    {:ok, %{cid: cid}} = KeyRotation.stage(c.did, c.expected, :p256, c.opts)
    Application.put_env(:atoll, :repository_quota, max_bytes: 0)
    assert {:error, :repository_quota_exceeded} = KeyRotation.resume(c.did, cid, c.opts)
    Application.delete_env(:atoll, :repository_quota)
    state = Agent.get(c.directory, & &1)
    {:ok, successor} = Operation.successor(state.last)

    {:ok, next} =
      Operation.sign(Map.put(successor, "alsoKnownAs", ["at://other.example.com"]), c.rotation)

    {:ok, next_cid} = Operation.cid(next)

    entry = %{
      "did" => c.did,
      "cid" => next_cid,
      "operation" => next,
      "nullified" => false,
      "createdAt" => "2026-01-03T00:00:00Z"
    }

    Agent.update(c.directory, &%{&1 | last: next, audit: &1.audit ++ [entry]})
    assert {:error, :plc_conflict} = KeyRotation.resume(c.did, cid, c.opts)
    assert KeyVault.fetch(c.did) == {:ok, c.old}
    assert {:ok, _} = PendingSigningKeys.fetch(c.did, cid)
  end

  test "identity change during completion lookup fences local publication", c do
    {:ok, %{cid: cid}} = KeyRotation.stage(c.did, c.expected, :p256, c.opts)
    counter = :counters.new(1, [])

    opts =
      Keyword.put(c.opts, :txt_lookup, fn _ ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 2 do
          Repo.insert!(%Atoll.Identity.Observation{
            did: c.did,
            handle: "alice.example.com",
            fingerprint: :binary.copy(<<1>>, 32)
          })
        end

        [["did=" <> c.did]]
      end)

    assert {:error, :stale_identity_refresh} = KeyRotation.resume(c.did, cid, opts)
    assert KeyVault.fetch(c.did) == {:ok, c.old}
    assert {:ok, _} = PendingSigningKeys.fetch(c.did, cid)
    assert {:ok, _} = KeyRotation.resume(c.did, cid, c.opts)
  end

  test "reconciliation rotates the repository after compatible advancement exactly once", c do
    {:ok, _} =
      Repositories.apply_writes(
        c.did,
        [
          {:put, "com.example.record/one",
           %{"$type" => "com.example.record", "text" => "retained"}}
        ],
        c.old
      )

    {:ok, record} = Repositories.get_record(c.did, "com.example.record/one")
    {:ok, prior_head} = Repositories.get_head(c.did)
    {:ok, %{cid: cid}} = KeyRotation.stage(c.did, c.expected, :p256, c.opts)
    row = Repo.get_by!(Update, did: c.did, cid: cid)
    {:ok, key} = PendingSigningKeys.fetch(c.did, cid)

    expected =
      advance(
        c,
        row,
        &put_in(&1, ["services", "extra"], %{
          "type" => "ExampleService",
          "endpoint" => "https://extra.example.com"
        })
      )

    seq = Events.latest_seq()
    assert {:ok, %{result: :completed}} = KeyRotation.reconcile(c.did, cid, expected, c.opts)
    assert KeyVault.fetch(c.did) == {:ok, key}
    assert Repositories.get_record(c.did, "com.example.record/one") == {:ok, record}
    {:ok, head} = Repositories.get_head(c.did)
    refute head.head == prior_head.head
    assert head.status == prior_head.status
    {:ok, bytes} = Atoll.Storage.get_block(head.head)
    assert {:ok, _} = Atoll.Commit.verify(bytes, c.did, key.curve, key.public)
    assert {:ok, [%{kind: :identity}, %{kind: :sync}]} = Events.list_after(seq)
    assert {:error, :key_not_found} = PendingSigningKeys.fetch(c.did, cid)
    audit = Repo.one!(Atoll.Moderation.AuditEntry)
    assert audit.operation == "atoll.keys.reconcilePlc"
    assert audit.requested["operationCid"] == cid
    assert audit.requested["observedHead"] == expected
    seq = Events.latest_seq()
    assert {:ok, _} = KeyRotation.reconcile(c.did, cid, expected, c.opts)
    assert Events.latest_seq() == seq
    assert Repositories.get_head(c.did) == {:ok, head}
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 1
    assert Agent.get(c.directory, & &1.posts) == 0
  end

  test "failed reconciliation publication rolls back confirmation, custody and events", c do
    {:ok, %{cid: cid}} = KeyRotation.stage(c.did, c.expected, :p256, c.opts)
    row = Repo.get_by!(Update, did: c.did, cid: cid)
    {:ok, key} = PendingSigningKeys.fetch(c.did, cid)
    expected = advance(c, row, & &1)
    {:ok, _} = Repositories.set_status(c.did, :deactivated)
    seq = Events.latest_seq()
    Application.put_env(:atoll, :repository_quota, max_bytes: 0)

    assert {:error, :repository_quota_exceeded} =
             KeyRotation.reconcile(c.did, cid, expected, c.opts)

    assert Events.latest_seq() == seq
    assert KeyVault.fetch(c.did) == {:ok, c.old}
    assert PendingSigningKeys.fetch(c.did, cid) == {:ok, key}
    assert is_nil(Repo.get_by!(Update, did: c.did, cid: cid).confirmed_at)
    assert is_nil(Repo.get_by!(Update, did: c.did, cid: cid).completed_at)
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 0
    Application.delete_env(:atoll, :repository_quota)
    assert {:ok, _} = KeyRotation.reconcile(c.did, cid, expected, c.opts)
    assert {:ok, %{status: :deactivated}} = Repositories.get_head(c.did)
    assert Agent.get(c.directory, & &1.posts) == 0
  end

  test "stale heads and changed remote identity cannot install a retained signing key", c do
    {:ok, %{cid: cid}} = KeyRotation.stage(c.did, c.expected, :p256, c.opts)
    row = Repo.get_by!(Update, did: c.did, cid: cid)
    {:ok, key} = PendingSigningKeys.fetch(c.did, cid)
    base = Agent.get(c.directory, & &1)
    {:ok, other} = Multikey.to_did_key(:k256, SigningKey.generate().public)

    for change <- [
          &put_in(&1, ["verificationMethods", "atproto"], other),
          &Map.put(&1, "alsoKnownAs", ["at://other.example.com"]),
          &put_in(&1, ["services", "atproto_pds", "endpoint"], "https://other.example.com"),
          &Map.put(&1, "rotationKeys", [other])
        ] do
      Agent.update(c.directory, fn _ -> base end)
      expected = advance(c, row, change)
      assert {:error, _} = KeyRotation.reconcile(c.did, cid, expected, c.opts)
      assert {:error, :plc_conflict} = KeyRotation.reconcile(c.did, cid, cid, c.opts)
      assert KeyVault.fetch(c.did) == {:ok, c.old}
      assert PendingSigningKeys.fetch(c.did, cid) == {:ok, key}
    end

    assert is_nil(Repo.get_by!(Update, did: c.did, cid: cid).confirmed_at)
    assert Agent.get(c.directory, & &1.posts) == 0
  end

  defp advance(c, row, change) do
    {:ok, unsigned} = Operation.successor(row.operation)
    {:ok, advanced} = Operation.sign(change.(unsigned), c.rotation)
    {:ok, expected} = Operation.cid(advanced)

    entry = fn operation, cid, date ->
      %{
        "did" => c.did,
        "operation" => operation,
        "cid" => cid,
        "nullified" => false,
        "createdAt" => date
      }
    end

    Agent.update(c.directory, fn state ->
      %{
        state
        | audit:
            state.audit ++
              [
                entry.(row.operation, row.cid, "2026-01-02T00:00:00Z"),
                entry.(advanced, expected, "2026-01-03T00:00:00Z")
              ],
          last: advanced
      }
    end)

    expected
  end

  test "operator CLI stages and resumes using public metadata only", c do
    Application.put_env(:atoll, :identity_resolution_options, Keyword.drop(c.opts, [:plug]))
    Application.put_env(:atoll, :plc_submission_options, Keyword.take(c.opts, [:plug]))

    stage =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Keys.RotatePlc.run(["stage", c.did, c.expected, "p256"])
      end)
      |> Jason.decode!()

    assert stage["result"] == "staged"

    status =
      ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Atoll.Keys.RotatePlc.run(["status", c.did]) end)
      |> Jason.decode!()

    assert status["cid"] == stage["cid"]
    assert status["confirmed"] == false
    assert Map.keys(stage) |> Enum.sort() == ["cid", "did", "key", "result"]

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Keys.RotatePlc.run(["resume", c.did, stage["cid"]])
      end)

    assert Jason.decode!(output)["result"] == "completed"
  end
end
