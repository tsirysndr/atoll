defmodule Atoll.PLCAuthorityRotationTest do
  use Atoll.DataCase, async: false
  alias Atoll.{KeyVault, Multikey, Repositories, SigningKey}
  alias Atoll.Accounts.Profile

  alias Atoll.Identity.PLC.{
    AuthorityRotation,
    Operation,
    PendingAuthorityKeys,
    Registrations,
    Update
  }

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
    {:ok, repository} = Multikey.to_did_key(old.curve, old.public)
    {:ok, expected} = Multikey.to_did_key(rotation.curve, rotation.public)
    {:ok, rotating} = Multikey.to_did_key(rotation.curve, rotation.public)
    {:ok, backup} = Multikey.to_did_key(:k256, SigningKey.generate().public)

    {:ok, genesis} =
      Operation.create_atproto(
        repository,
        "alice.example.com",
        AtollWeb.Endpoint.url(),
        [backup, rotating],
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

  test "stage preserves identity fields and resume installs once with an audit", c do
    seq = Events.latest_seq()

    assert {:ok, %{cid: cid, result: :staged}} =
             AuthorityRotation.stage(c.did, c.expected, :p256, c.opts)

    row = Repo.get_by!(Update, did: c.did, cid: cid)
    assert {:ok, successor} = Operation.successor(row.previous)

    assert Map.drop(row.operation, ["sig", "rotationKeys"]) ==
             Map.delete(successor, "rotationKeys")

    assert hd(row.operation["rotationKeys"]) == hd(successor["rotationKeys"])
    assert length(row.operation["rotationKeys"]) == 2
    assert KeyVault.fetch(c.did) == {:ok, c.old}
    assert Events.latest_seq() == seq
    assert {:ok, key} = PendingAuthorityKeys.fetch(c.did, cid)
    assert {:ok, %{result: :completed}} = AuthorityRotation.resume(c.did, cid, c.opts)
    assert Registrations.rotation_key(c.did) == {:ok, key}
    assert KeyVault.fetch(c.did) == {:ok, c.old}
    assert {:error, :key_not_found} = PendingAuthorityKeys.fetch(c.did, cid)
    assert Events.latest_seq() == seq
    assert Repositories.get_head(c.did) == {:ok, c.head}
    assert Repo.one!(Atoll.Moderation.AuditEntry).operation == "atoll.plc.rotateAuthority"
    seq = Events.latest_seq()
    assert {:ok, %{result: :completed}} = AuthorityRotation.resume(c.did, cid, c.opts)
    assert Events.latest_seq() == seq
    assert Agent.get(c.directory, & &1.posts) == 1
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 1
    {:ok, repository_key} = Multikey.to_did_key(c.old.curve, c.old.public)

    assert {:ok, %{cid: next_cid}} =
             Atoll.Identity.PLC.KeyRotation.stage(c.did, repository_key, :p256, c.opts)

    next = Repo.get_by!(Update, did: c.did, cid: next_cid)
    assert {:ok, _} = Operation.verify_update(row.operation, next.operation)
  end

  test "ambiguous acceptance resumes the same encrypted key without reposting", c do
    {:ok, %{cid: cid}} = AuthorityRotation.stage(c.did, c.expected, :p256, c.opts)
    {:ok, key} = PendingAuthorityKeys.fetch(c.did, cid)
    Agent.update(c.directory, &%{&1 | ambiguous: true})
    assert {:error, :plc_unavailable} = AuthorityRotation.resume(c.did, cid, c.opts)
    assert PendingAuthorityKeys.fetch(c.did, cid) == {:ok, key}
    assert KeyVault.fetch(c.did) == {:ok, c.old}
    Agent.update(c.directory, &%{&1 | unavailable: false})
    assert {:ok, _} = AuthorityRotation.resume(c.did, cid, c.opts)
    assert Registrations.rotation_key(c.did) == {:ok, key}
    assert KeyVault.fetch(c.did) == {:ok, c.old}
    assert Agent.get(c.directory, & &1.posts) == 1
  end

  test "stale keys and conflicting pending work reject staging", c do
    {:ok, wrong} = Multikey.to_did_key(:k256, SigningKey.generate().public)
    assert {:error, _} = AuthorityRotation.stage(c.did, wrong, :p256, c.opts)
    assert Repo.aggregate(Update, :count) == 0
    backup = Agent.get(c.directory, &hd(&1.last["rotationKeys"]))
    assert {:error, :stale_rotation_key} = AuthorityRotation.stage(c.did, backup, :p256, c.opts)
    {:ok, %{cid: cid}} = AuthorityRotation.stage(c.did, c.expected, :p256, c.opts)

    assert {:error, :plc_update_pending} =
             AuthorityRotation.stage(c.did, c.expected, :p256, c.opts)

    assert Repo.get_by!(Update, did: c.did, cid: cid).authority_envelope

    Repo.get!(Profile, c.did)
    |> Ecto.Changeset.change(handle: "other.example.com")
    |> Repo.update!()

    assert {:error, :invalid_key_rotation} = AuthorityRotation.resume(c.did, cid, c.opts)
    assert Agent.get(c.directory, & &1.posts) == 0
  end

  test "missing rotation authority leaves no pending key or operation", c do
    Repo.delete!(Repo.get!(Atoll.Identity.PLC.Registration, c.did))

    assert {:error, :registration_not_found} =
             AuthorityRotation.stage(c.did, c.expected, :p256, c.opts)

    assert Repo.aggregate(Update, :count) == 0
    assert Agent.get(c.directory, & &1.posts) == 0
  end

  test "suspension blocks submission and deactivation is preserved on completion", c do
    {:ok, %{cid: cid}} = AuthorityRotation.stage(c.did, c.expected, :p256, c.opts)
    {:ok, _} = Repositories.set_status(c.did, :suspended)
    assert {:error, :repo_inactive} = AuthorityRotation.resume(c.did, cid, c.opts)
    assert Agent.get(c.directory, & &1.posts) == 0
    {:ok, _} = Repositories.set_status(c.did, :deactivated)
    assert {:ok, _} = AuthorityRotation.resume(c.did, cid, c.opts)
    assert {:ok, %{status: :deactivated}} = Repositories.get_head(c.did)
  end

  test "a later directory operation cannot complete an earlier rotation", c do
    {:ok, %{cid: cid}} = AuthorityRotation.stage(c.did, c.expected, :p256, c.opts)
    Agent.update(c.directory, &%{&1 | ambiguous: true})
    assert {:error, :plc_unavailable} = AuthorityRotation.resume(c.did, cid, c.opts)
    {:ok, key} = PendingAuthorityKeys.fetch(c.did, cid)
    state = Agent.get(c.directory, & &1)
    {:ok, successor} = Operation.successor(state.last)

    {:ok, next} =
      Operation.sign(Map.put(successor, "alsoKnownAs", ["at://other.example.com"]), key)

    {:ok, next_cid} = Operation.cid(next)

    entry = %{
      "did" => c.did,
      "cid" => next_cid,
      "operation" => next,
      "nullified" => false,
      "createdAt" => "2026-01-03T00:00:00Z"
    }

    Agent.update(c.directory, &%{&1 | last: next, audit: &1.audit ++ [entry], unavailable: false})
    assert {:error, :plc_conflict} = AuthorityRotation.resume(c.did, cid, c.opts)
    assert Registrations.rotation_key(c.did) == {:ok, c.rotation}
    assert PendingAuthorityKeys.fetch(c.did, cid) == {:ok, key}
  end

  test "identity change during completion lookup fences local publication", c do
    {:ok, %{cid: cid}} = AuthorityRotation.stage(c.did, c.expected, :p256, c.opts)
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

    assert {:error, :stale_identity_refresh} = AuthorityRotation.resume(c.did, cid, opts)
    assert KeyVault.fetch(c.did) == {:ok, c.old}
    assert {:ok, _} = PendingAuthorityKeys.fetch(c.did, cid)
    assert {:ok, _} = AuthorityRotation.resume(c.did, cid, c.opts)
  end

  test "operator CLI stages and resumes using public metadata only", c do
    Application.put_env(:atoll, :identity_resolution_options, Keyword.drop(c.opts, [:plug]))
    Application.put_env(:atoll, :plc_submission_options, Keyword.take(c.opts, [:plug]))

    stage =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Plc.RotateAuthority.run(["stage", c.did, c.expected, "p256"])
      end)
      |> Jason.decode!()

    assert stage["result"] == "staged"

    status =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Plc.RotateAuthority.run(["status", c.did])
      end)
      |> Jason.decode!()

    assert status["cid"] == stage["cid"]
    assert status["confirmed"] == false
    assert Map.keys(stage) |> Enum.sort() == ["cid", "did", "key", "result"]

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Plc.RotateAuthority.run(["resume", c.did, stage["cid"]])
      end)

    assert Jason.decode!(output)["result"] == "completed"
  end
end
