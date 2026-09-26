defmodule Atoll.HandleChangesTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Repositories, SigningKey, Multikey}
  alias Atoll.Accounts.{Profile, Sessions, Signup}
  alias Atoll.Identity.{HandleChanges, HandleReservation}
  alias Atoll.Identity.PLC.{Operation, Update}

  setup do
    settings = [:session_signing_key, :pds, :signup_enabled, :invite_code_required]
    prior = Map.new(settings, &{&1, Application.fetch_env(:atoll, &1)})
    endpoint = Application.fetch_env!(:atoll, AtollWeb.Endpoint)

    AtollWeb.Endpoint.config_change(
      [
        {AtollWeb.Endpoint,
         Keyword.put(endpoint, :url, scheme: "https", host: "pds.example.com", port: 443)}
      ],
      []
    )

    Application.put_env(:atoll, :session_signing_key, :crypto.strong_rand_bytes(32))

    Application.put_env(:atoll, :pds,
      did: "did:web:pds.example.com",
      available_user_domains: [".example.com"]
    )

    Application.put_env(:atoll, :signup_enabled, true)
    Application.put_env(:atoll, :invite_code_required, false)

    on_exit(fn ->
      AtollWeb.Endpoint.config_change([{AtollWeb.Endpoint, endpoint}], [])

      for {key, value} <- prior do
        case value do
          {:ok, val} -> Application.put_env(:atoll, key, val)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    account("alice.example.com")
  end

  test "full-session owner reserves a hosted name and exact retries preserve the journal", ctx do
    op = operation(ctx, "bob.example.com")

    assert {:ok, result} =
             HandleChanges.stage(ctx.pair.access_jwt, "BOB.example.com", ctx.audit, op)

    assert Repo.get!(Profile, ctx.did).handle == "alice.example.com"
    assert Repo.get!(HandleReservation, "bob.example.com").cid == result.cid

    assert {:ok, ^result} =
             HandleChanges.stage(ctx.pair.access_jwt, "bob.example.com", ctx.audit, op)

    assert Repo.aggregate(Update, :count) == 1
    assert HandleChanges.claimed?("bob.example.com")

    assert {:error, :handle_not_available} =
             Signup.create(%{"handle" => "bob.example.com", "password" => "signup password"})

    other = account("charlie.example.com")

    assert {:error, :handle_not_available} =
             HandleChanges.stage(
               other.pair.access_jwt,
               "bob.example.com",
               other.audit,
               operation(other, "bob.example.com")
             )
  end

  test "custom names require a fresh forward claim and token revocation during lookup blocks staging",
       ctx do
    handle = "custom.other.com"
    op = operation(ctx, handle)
    opts = [txt_lookup: fn _ -> [["did=" <> ctx.did]] end]
    assert {:ok, _} = HandleChanges.stage(ctx.pair.access_jwt, handle, ctx.audit, op, opts)
    assert Repo.get!(HandleReservation, handle)
    Repo.delete_all(HandleReservation)
    Repo.delete_all(Update)

    opts = [
      txt_lookup: fn _ ->
        Sessions.revoke(ctx.pair.refresh_jwt)
        [["did=" <> ctx.did]]
      end
    ]

    assert {:error, :invalid_token} =
             HandleChanges.stage(ctx.pair.access_jwt, handle, ctx.audit, op, opts)

    assert Repo.aggregate(Update, :count) == 0
  end

  test "handle-only staging rejects key/service changes, occupied handles and inactive accounts",
       ctx do
    op = operation(ctx, "bob.example.com")
    bad = put_in(op, ["services", "atproto_pds", "endpoint"], "https://other.example.com")

    assert {:error, :invalid_handle_update} =
             HandleChanges.stage(ctx.pair.access_jwt, "bob.example.com", ctx.audit, bad)

    account("bob.example.com")

    assert {:error, :handle_not_available} =
             HandleChanges.stage(ctx.pair.access_jwt, "bob.example.com", ctx.audit, op)

    {:ok, _} = Repositories.set_status(ctx.did, :deactivated)

    assert {:error, {:repo_inactive, :deactivated}} =
             HandleChanges.stage(ctx.pair.access_jwt, "bob.example.com", ctx.audit, op)

    assert Repo.aggregate(Update, :count) == 0
  end

  test "restricted sessions cannot reserve names and account deletion releases reservations",
       ctx do
    {:ok, app} =
      Atoll.Accounts.AppPasswords.create(ctx.pair.access_jwt, %{"name" => "handle test"})

    {:ok, pair} = Sessions.create(ctx.did, app.password)
    op = operation(ctx, "bob.example.com")

    assert {:error, :forbidden} =
             HandleChanges.stage(pair.access_jwt, "bob.example.com", ctx.audit, op)

    assert {:ok, _} = HandleChanges.stage(ctx.pair.access_jwt, "bob.example.com", ctx.audit, op)
    Repo.delete!(Repo.get!(Atoll.Repositories.Head, ctx.did))
    refute HandleChanges.claimed?("bob.example.com")
  end

  test "completion atomically changes the profile, observation and event and releases the name",
       ctx do
    op = operation(ctx, "bob.example.com")
    {:ok, row} = HandleChanges.stage(ctx.pair.access_jwt, "bob.example.com", ctx.audit, op)
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, op))

    assert {:ok, _} =
             Atoll.Identity.PLC.Updates.submit(ctx.did, row.cid, plug: {Req.Test, __MODULE__})

    audit =
      ctx.audit ++
        [
          %{
            "did" => ctx.did,
            "cid" => row.cid,
            "operation" => op,
            "nullified" => false,
            "createdAt" => "2026-01-02T00:00:00Z"
          }
        ]

    for _ <- 1..2 do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, audit))
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, op))

      assert {:ok, %{handle: "bob.example.com"}} =
               HandleChanges.complete(ctx.pair.access_jwt, row.cid, plug: {Req.Test, __MODULE__})
    end

    assert Repo.get!(Profile, ctx.did).handle == "bob.example.com"
    assert Repo.get!(Atoll.Identity.Observation, ctx.did).handle == "bob.example.com"
    assert Repo.get_by!(Update, did: ctx.did, cid: row.cid).completed_at
    assert Repo.aggregate(HandleReservation, :count) == 0

    assert Repo.aggregate(from(e in Atoll.Repositories.Event, where: e.kind == :identity), :count) ==
             1

    refute HandleChanges.claimed?("alice.example.com")
  end

  test "confirmation alone cannot finish after directory state changes", ctx do
    op = operation(ctx, "bob.example.com")
    {:ok, row} = HandleChanges.stage(ctx.pair.access_jwt, "bob.example.com", ctx.audit, op)
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, op))
    {:ok, _} = Atoll.Identity.PLC.Updates.submit(ctx.did, row.cid, plug: {Req.Test, __MODULE__})
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, ctx.audit))
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, ctx.genesis.operation))

    assert {:error, :plc_conflict} =
             HandleChanges.complete(ctx.pair.access_jwt, row.cid, plug: {Req.Test, __MODULE__})

    assert Repo.get!(Profile, ctx.did).handle == "alice.example.com"
    refute Repo.get_by!(Update, did: ctx.did, cid: row.cid).completed_at
    assert HandleChanges.claimed?("bob.example.com")
  end

  test "legacy predecessors can stage and complete a modern handle-only update", ctx do
    key = SigningKey.generate()
    {:ok, signing} = Multikey.to_did_key(key.curve, key.public)
    {:ok, recovery} = Multikey.to_did_key(ctx.rotation.curve, ctx.rotation.public)

    unsigned = %{
      "type" => "create",
      "signingKey" => signing,
      "recoveryKey" => recovery,
      "handle" => "legacy.example.com",
      "service" => "pds.example.com",
      "prev" => nil
    }

    {:ok, signature} = SigningKey.sign(ctx.rotation, Atoll.CBOR.encode!(unsigned))
    previous = Map.put(unsigned, "sig", Base.url_encode64(signature, padding: false))
    {:ok, did} = Operation.genesis_did(previous)
    {:ok, previous_cid} = Operation.cid(previous)
    {:ok, _} = Repositories.create(did, key)
    Repo.insert!(%Profile{did: did, handle: "legacy.example.com"})
    {:ok, pair} = Sessions.create_for_account(did)

    audit = [
      %{
        "did" => did,
        "cid" => previous_cid,
        "operation" => previous,
        "nullified" => false,
        "createdAt" => "2026-01-01T00:00:00Z"
      }
    ]

    {:ok, next} = Operation.successor(previous)
    next = Map.put(next, "alsoKnownAs", ["at://newlegacy.example.com"])
    {:ok, op} = Operation.sign(next, ctx.rotation)
    assert {:ok, row} = HandleChanges.stage(pair.access_jwt, "newlegacy.example.com", audit, op)
    assert Repo.get_by!(Update, did: did, cid: row.cid).previous == previous
    assert op["rotationKeys"] == [recovery, signing]
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, op))

    assert {:ok, _} =
             Atoll.Identity.PLC.Updates.submit(did, row.cid, plug: {Req.Test, __MODULE__})

    audit =
      audit ++
        [
          %{
            "did" => did,
            "cid" => row.cid,
            "operation" => op,
            "nullified" => false,
            "createdAt" => "2026-01-02T00:00:00Z"
          }
        ]

    Req.Test.expect(__MODULE__, &Req.Test.json(&1, audit))
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, op))

    assert {:ok, %{handle: "newlegacy.example.com"}} =
             HandleChanges.complete(pair.access_jwt, row.cid, plug: {Req.Test, __MODULE__})

    assert Repo.get!(Profile, did).handle == "newlegacy.example.com"
  end

  defp account(handle) do
    key = SigningKey.generate()
    rotation = SigningKey.generate()
    {:ok, signing} = Multikey.to_did_key(key.curve, key.public)
    {:ok, rotating} = Multikey.to_did_key(rotation.curve, rotation.public)

    {:ok, genesis} =
      Operation.create_atproto(signing, handle, AtollWeb.Endpoint.url(), [rotating], rotation)

    {:ok, _} = Repositories.create(genesis.did, key)
    Repo.insert!(%Profile{did: genesis.did, handle: handle})
    {:ok, pair} = Sessions.create_for_account(genesis.did)

    audit = [
      %{
        "did" => genesis.did,
        "cid" => genesis.cid,
        "operation" => genesis.operation,
        "nullified" => false,
        "createdAt" => "2026-01-01T00:00:00Z"
      }
    ]

    %{did: genesis.did, genesis: genesis, rotation: rotation, audit: audit, pair: pair}
  end

  defp operation(ctx, handle) do
    unsigned =
      ctx.genesis.operation
      |> Map.delete("sig")
      |> Map.put("prev", ctx.genesis.cid)
      |> Map.put("alsoKnownAs", ["at://" <> handle])

    {:ok, op} = Operation.sign(unsigned, ctx.rotation)
    op
  end
end
