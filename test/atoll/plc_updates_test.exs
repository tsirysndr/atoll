defmodule Atoll.PLCUpdatesTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Repositories, SigningKey, Multikey}
  alias Atoll.Identity.PLC.{Operation, Update, Updates}
  alias Atoll.Repositories.Head

  setup do
    repo_key = SigningKey.generate()
    rotation = SigningKey.generate()
    {:ok, signing} = Multikey.to_did_key(repo_key.curve, repo_key.public)
    {:ok, rotating} = Multikey.to_did_key(rotation.curve, rotation.public)

    {:ok, genesis} =
      Operation.create_atproto(
        signing,
        "alice.example.com",
        "https://pds.example.com",
        [rotating],
        rotation
      )

    {:ok, _} = Repositories.create(genesis.did, repo_key)

    audit = [
      %{
        "did" => genesis.did,
        "cid" => genesis.cid,
        "operation" => genesis.operation,
        "nullified" => false,
        "createdAt" => "2026-01-01T00:00:00Z"
      }
    ]

    unsigned =
      genesis.operation
      |> Map.delete("sig")
      |> Map.put("prev", genesis.cid)
      |> Map.put("alsoKnownAs", ["at://bob.example.com"])

    {:ok, operation} = Operation.sign(unsigned, rotation)
    {:ok, cid} = Operation.cid(operation)

    %{
      did: genesis.did,
      audit: audit,
      previous: genesis.operation,
      operation: operation,
      cid: cid,
      rotation: rotation
    }
  end

  test "staging verifies DID history and persists an exact immutable retry", ctx do
    assert {:ok, %{confirmed: false, completed: false}} = stage(ctx)
    row = Repo.get_by!(Update, did: ctx.did, cid: ctx.cid)
    assert row.previous == ctx.previous
    assert row.operation == ctx.operation
    assert {:ok, _} = stage(ctx)
    assert Repo.get_by!(Update, did: ctx.did, cid: ctx.cid) == row

    {:ok, other} =
      ctx.operation
      |> Map.delete("sig")
      |> Map.put("alsoKnownAs", ["at://charlie.example.com"])
      |> Operation.sign(ctx.rotation)

    assert {:error, :plc_update_pending} = Updates.stage(ctx.did, ctx.audit, other)
    assert Repo.aggregate(Update, :count) == 1

    assert {:error, :invalid_plc_log} =
             Updates.stage("did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", ctx.audit, ctx.operation)

    assert {:error, :invalid_plc_operation} =
             Updates.stage(ctx.did, ctx.audit, Map.put(ctx.operation, "sig", "bad"))

    assert {:error, :invalid_plc_operation} = Updates.stage(ctx.did, ctx.audit, nil)
  end

  test "staging rolls back with local reservations and submit refuses an open transaction", ctx do
    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, _} = stage(ctx)
               assert {:error, :plc_update_inside_transaction} = Updates.submit(ctx.did, ctx.cid)
               Repo.rollback(:cancelled)
             end)

    assert Repo.aggregate(Update, :count) == 0
  end

  test "ambiguous delivery preserves the exact update and retries confirm without reposting",
       ctx do
    {:ok, _} = stage(ctx)
    expect_get(ctx.previous)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(bytes) == ctx.operation
      Req.Test.transport_error(conn, :timeout)
    end)

    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))
    assert {:error, :plc_unavailable} = submit(ctx)
    row = Repo.get_by!(Update, did: ctx.did, cid: ctx.cid)
    assert is_nil(row.confirmed_at)
    assert row.operation == ctx.operation
    expect_get(ctx.operation)
    assert {:ok, %{confirmed: true, completed: false}} = submit(ctx)
    confirmed = Repo.get_by!(Update, did: ctx.did, cid: ctx.cid)
    assert confirmed.confirmed_at
    assert {:ok, %{confirmed: true}} = submit(ctx)
    assert Repo.get_by!(Update, did: ctx.did, cid: ctx.cid) == confirmed
    assert Repo.get!(Head, ctx.did).status == :active
  end

  test "completion requires confirmation and rolls back with local mutations", ctx do
    {:ok, _} = stage(ctx)

    assert {:error, :plc_update_unconfirmed} =
             Repo.transaction(fn -> Updates.complete!(ctx.did, ctx.cid) end)

    assert_raise ArgumentError, fn -> Updates.complete!(ctx.did, ctx.cid) end
    expect_get(ctx.operation)
    assert {:ok, _} = submit(ctx)

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert %{completed: true} = Updates.complete!(ctx.did, ctx.cid)
               Repo.rollback(:cancelled)
             end)

    refute Repo.get_by!(Update, did: ctx.did, cid: ctx.cid).completed_at

    assert {:ok, %{completed: true}} =
             Repo.transaction(fn -> Updates.complete!(ctx.did, ctx.cid) end)

    completed = Repo.get_by!(Update, did: ctx.did, cid: ctx.cid).completed_at
    assert {:ok, _} = Repo.transaction(fn -> Updates.complete!(ctx.did, ctx.cid) end)
    assert Repo.get_by!(Update, did: ctx.did, cid: ctx.cid).completed_at == completed
    assert {:ok, %{completed: true}} = submit(ctx)

    {:ok, next} =
      ctx.operation
      |> Map.delete("sig")
      |> Map.put("prev", ctx.cid)
      |> Map.put("alsoKnownAs", ["at://charlie.example.com"])
      |> Operation.sign(ctx.rotation)

    audit =
      ctx.audit ++
        [
          %{
            "did" => ctx.did,
            "cid" => ctx.cid,
            "operation" => ctx.operation,
            "nullified" => false,
            "createdAt" => "2026-01-02T00:00:00Z"
          }
        ]

    assert {:ok, %{confirmed: false, completed: false}} = Updates.stage(ctx.did, audit, next)
    assert Repo.aggregate(Update, :count) == 2
  end

  test "tampering or deletion fails closed without resurrecting journal entries", ctx do
    {:ok, _} = stage(ctx)
    Repo.update_all(Update, set: [operation: Map.put(ctx.operation, "sig", "bad")])
    assert {:error, :invalid_plc_operation} = submit(ctx)
    Repo.delete!(Repo.get!(Head, ctx.did))
    assert Repo.aggregate(Update, :count) == 0
    assert {:error, :plc_update_not_found} = submit(ctx)
    assert {:error, :account_not_found} = stage(ctx)
  end

  test "directory-backed staging checks fresh evidence outside the local transaction", ctx do
    Req.Test.expect(__MODULE__, fn conn ->
      assert String.ends_with?(conn.request_path, "/log/audit")
      Req.Test.json(conn, ctx.audit)
    end)

    expect_get(ctx.previous)

    assert {:ok, %{confirmed: false}} =
             Updates.stage_from_directory(ctx.did, ctx.operation, plug: {Req.Test, __MODULE__})

    assert Repo.get_by!(Update, did: ctx.did, cid: ctx.cid).operation == ctx.operation

    assert {:ok, {:error, :plc_update_inside_transaction}} =
             Repo.transaction(fn ->
               Updates.stage_from_directory(ctx.did, ctx.operation)
             end)
  end

  defp stage(ctx), do: Updates.stage(ctx.did, ctx.audit, ctx.operation)
  defp submit(ctx), do: Updates.submit(ctx.did, ctx.cid, plug: {Req.Test, __MODULE__})

  defp expect_get(operation) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, operation)
    end)
  end
end
