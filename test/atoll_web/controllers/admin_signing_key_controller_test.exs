defmodule AtollWeb.AdminSigningKeyControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{KeyVault, Multikey, Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{AdminSigningKey, Profile}
  alias Atoll.Identity.PLC.{Operation, Registrations, Update, Updates}
  alias Atoll.Repositories.Events
  @path "/xrpc/com.atproto.admin.updateAccountSigningKey"

  setup do
    for name <- [
          :key_encryption_key,
          :admin_password,
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
    Application.put_env(:atoll, :admin_password, "admin-signing-key-test-secret-at-least-32")
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

    Repo.update_all(Atoll.Identity.PLC.Registration,
      set: [confirmed_at: DateTime.utc_now(), completed_at: DateTime.utc_now()]
    )

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
      refute Repo.in_transaction?()
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

  test "directory updates preserve every other identity field and local repository custody", c do
    key = SigningKey.generate(:p256)
    {:ok, public} = Multikey.to_did_key(key.curve, key.public)
    before = Agent.get(c.directory, & &1.last)
    {:ok, head} = Repositories.get_head(c.did)
    seq = Events.latest_seq()
    Application.put_env(:atoll, :plc_submission_options, c.opts)
    response = auth(build_conn()) |> post(@path, %{did: c.did, signingKey: public})
    assert response(response, 200) == ""
    assert get_resp_header(response, "cache-control") == ["no-store"]
    updated = Agent.get(c.directory, & &1.last)

    assert updated["verificationMethods"] ==
             Map.put(before["verificationMethods"], "atproto", public)

    assert Map.drop(updated, ["verificationMethods", "prev", "sig"]) ==
             Map.drop(before, ["verificationMethods", "prev", "sig"])

    assert {:ok, ^head} = Repositories.get_head(c.did)
    assert KeyVault.fetch(c.did) == {:ok, c.old}
    row = Repo.one!(Update)
    assert (row.directory_key_update and row.confirmed_at) && row.completed_at
    assert is_nil(row.signing_envelope)
    {:ok, [event]} = Events.list_after(seq)
    assert event.kind == :identity
    assert {:ok, "#identity", body} = Atoll.Repositories.EventEncoder.message(event)
    assert body["did"] == c.did
    refute Map.has_key?(body, "handle")
    audits = Repo.all(Atoll.Moderation.AuditEntry)
    assert Enum.map(audits, & &1.requested["phase"]) |> Enum.sort() == ["completed", "staged"]
    assert Enum.all?(audits, &(&1.actor == "admin"))
    refute Jason.encode!(Enum.map(audits, & &1.requested)) =~ "private"
    seq = Events.latest_seq()

    assert {:ok, :unchanged} =
             AdminSigningKey.update(%{"did" => c.did, "signingKey" => public}, c.opts)

    assert Agent.get(c.directory, & &1.posts) == 1
    assert Events.latest_seq() == seq
  end

  test "ambiguous publication retries the exact signed operation without duplicate POST or completion",
       c do
    params = params(c)
    Agent.update(c.directory, &%{&1 | ambiguous: true})
    assert {:error, :plc_unavailable} = AdminSigningKey.update(params, c.opts)
    row = Repo.one!(Update)
    assert row.directory_key_update and is_nil(row.completed_at)
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 1
    assert {:error, :plc_update_pending} = AdminSigningKey.update(params(c), c.opts)
    Agent.update(c.directory, &%{&1 | ambiguous: false, unavailable: false})

    assert {:error, :plc_update_pending} =
             Updates.stage(c.did, Agent.get(c.directory, & &1.audit), row.operation)

    assert {:ok, :updated} = AdminSigningKey.update(params, c.opts)
    assert Repo.one!(Update).operation == row.operation
    assert Agent.get(c.directory, & &1.posts) == 1
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 2
    assert KeyVault.fetch(c.did) == {:ok, c.old}
  end

  test "audit failure rolls back intent and prevents directory submission", c do
    Repo.query!(
      "ALTER TABLE moderation_audit_entries ADD CONSTRAINT reject_admin_key CHECK (operation <> 'com.atproto.admin.updateAccountSigningKey')"
    )

    assert_raise Ecto.ConstraintError, fn -> AdminSigningKey.update(params(c), c.opts) end
    assert Repo.aggregate(Update, :count) == 0
    assert Agent.get(c.directory, & &1.posts) == 0
    assert KeyVault.fetch(c.did) == {:ok, c.old}
  end

  test "completion audit failure leaves accepted intent retryable without another publication",
       c do
    params = params(c)
    seq = Events.latest_seq()

    Repo.query!(
      "ALTER TABLE moderation_audit_entries ADD CONSTRAINT reject_admin_key_completion CHECK (requested->>'phase' <> 'completed')"
    )

    assert_raise Ecto.ConstraintError, fn -> AdminSigningKey.update(params, c.opts) end
    assert Repo.one!(Update).confirmed_at
    assert is_nil(Repo.one!(Update).completed_at)
    assert Events.latest_seq() == seq
    assert Agent.get(c.directory, & &1.posts) == 1

    Repo.query!(
      "ALTER TABLE moderation_audit_entries DROP CONSTRAINT reject_admin_key_completion"
    )

    assert {:ok, :updated} = AdminSigningKey.update(params, c.opts)
    assert Agent.get(c.directory, & &1.posts) == 1
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 2
  end

  test "operator authentication precedes JSON parsing; validation and unavailable directory leave no journal",
       c do
    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post(@path, "{")
           |> json_response(401)

    assert auth(build_conn())
           |> put_req_header("content-type", "application/json")
           |> post(@path, "{")
           |> json_response(400)

    assert auth(build_conn())
           |> put_req_header("content-type", "application/json")
           |> post(@path, String.duplicate(" ", 16385))
           |> json_response(413)

    for params <- [
          %{},
          %{"did" => c.did, "signingKey" => "did:key:bad"},
          %{"did" => "did:web:example.com", "signingKey" => c.expected},
          %{"did" => c.did, "signingKey" => c.expected, "privateKey" => "no"}
        ] do
      assert {:error, :invalid_request} = AdminSigningKey.update(params, c.opts)
    end

    assert {:error, :admin_account_not_found} =
             AdminSigningKey.update(
               %{"did" => "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", "signingKey" => c.expected},
               c.opts
             )

    Agent.update(c.directory, &%{&1 | unavailable: true})
    Application.put_env(:atoll, :plc_submission_options, c.opts)
    assert auth(build_conn()) |> post(@path, params(c)) |> json_response(503)
    assert Repo.aggregate(Update, :count) == 0
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 0
  end

  test "pending signup is rejected while inactive completed accounts keep their status", c do
    Repo.update_all(Atoll.Identity.PLC.Registration, set: [completed_at: nil])
    assert {:error, :signup_pending} = AdminSigningKey.update(params(c), c.opts)

    Repo.update_all(Atoll.Identity.PLC.Registration,
      set: [confirmed_at: DateTime.utc_now(), completed_at: DateTime.utc_now()]
    )

    {:ok, _} = Repositories.set_status(c.did, :deactivated)
    assert {:ok, :updated} = AdminSigningKey.update(params(c), c.opts)
    assert {:ok, %{status: :deactivated}} = Repositories.get_head(c.did)
  end

  test "a different pending workflow cannot be taken over by an administrative key request", c do
    state = Agent.get(c.directory, & &1)
    {:ok, successor} = Operation.successor(state.last)

    {:ok, operation} =
      Operation.sign(Map.put(successor, "alsoKnownAs", ["at://other.example.com"]), c.rotation)

    {:ok, _} = Updates.stage(c.did, state.audit, operation)
    assert {:error, :plc_update_pending} = AdminSigningKey.update(params(c), c.opts)
    refute Repo.one!(Update).directory_key_update
    assert Agent.get(c.directory, & &1.posts) == 0
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 0
  end

  test "directory advancement preserves the exact unresolved journal instead of re-signing", c do
    params = params(c)
    Agent.update(c.directory, &%{&1 | ambiguous: true})
    assert {:error, :plc_unavailable} = AdminSigningKey.update(params, c.opts)
    row = Repo.one!(Update)
    state = Agent.get(c.directory, & &1)
    {:ok, successor} = Operation.successor(state.last)

    {:ok, advanced} =
      Operation.sign(Map.put(successor, "alsoKnownAs", ["at://other.example.com"]), c.rotation)

    {:ok, cid} = Operation.cid(advanced)

    Agent.update(
      c.directory,
      &%{
        &1
        | unavailable: false,
          ambiguous: false,
          last: advanced,
          audit:
            &1.audit ++
              [
                %{
                  "did" => c.did,
                  "cid" => cid,
                  "operation" => advanced,
                  "nullified" => false,
                  "createdAt" => "2026-01-03T00:00:00Z"
                }
              ]
      }
    )

    assert {:error, :plc_conflict} = AdminSigningKey.update(params, c.opts)
    assert Repo.one!(Update).operation == row.operation
    assert is_nil(Repo.one!(Update).completed_at)
    assert Agent.get(c.directory, & &1.posts) == 1
    assert Repo.aggregate(Atoll.Moderation.AuditEntry, :count) == 1
  end

  defp params(c) do
    key = SigningKey.generate()
    {:ok, public} = Multikey.to_did_key(key.curve, key.public)
    %{"did" => c.did, "signingKey" => public}
  end

  defp auth(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header(
      "authorization",
      "Basic " <> Base.encode64("admin:admin-signing-key-test-secret-at-least-32")
    )
  end
end
