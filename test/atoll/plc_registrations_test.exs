defmodule Atoll.PLCRegistrationsTest do
  use Atoll.DataCase, async: false
  alias Atoll.{KeyVault, Multikey, Repositories, SigningKey}
  alias Atoll.Accounts.Profile
  alias Atoll.Identity.PLC.{Operation, Registration, Registrations}
  alias Atoll.Repositories.Head

  setup do
    previous = Application.get_env(:atoll, :key_encryption_key)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:atoll, :key_encryption_key, previous),
        else: Application.delete_env(:atoll, :key_encryption_key)
    end)

    :ok
  end

  test "staging persists the exact genesis and a separately encrypted, recoverable rotation key" do
    for curve <- [:k256, :p256] do
      ctx = account("alice-#{curve}.example.com", curve)

      assert {:ok, %{did: did, cid: cid}} =
               Registrations.stage(ctx.did, ctx.operation, ctx.rotation)

      assert did == ctx.did
      assert cid == ctx.cid
      row = Repo.get!(Registration, did)
      assert row.operation == ctx.operation
      assert is_nil(row.confirmed_at)
      assert byte_size(row.rotation_envelope) == 61
      assert :binary.match(row.rotation_envelope, ctx.rotation.private) == :nomatch
      refute inspect(row, limit: :infinity) =~ "rotation_envelope:"
      assert {:ok, key} = Registrations.rotation_key(did)
      assert key == ctx.rotation
      assert {:ok, repository_key} = KeyVault.fetch(did)
      refute key.public == repository_key.public

      assert {:ok, %{did: ^did, cid: ^cid}} =
               Registrations.stage(did, ctx.operation, ctx.rotation)

      assert Repo.get!(Registration, did).rotation_envelope == row.rotation_envelope
      assert Repo.get!(Head, did).status == :deactivated
    end
  end

  test "staging is atomic with the outer provisioning transaction" do
    assert {:error, :cancel} =
             Repo.transaction(fn ->
               ctx = account()
               assert {:ok, _} = Registrations.stage(ctx.did, ctx.operation, ctx.rotation)
               assert {:error, :registration_inside_transaction} = Registrations.submit(ctx.did)
               Repo.rollback(:cancel)
             end)

    assert Repo.aggregate(Registration, :count) == 0
    assert Repo.aggregate(Profile, :count) == 0
  end

  test "stage requires a deactivated matching profile, repository, and retained repository key" do
    ctx = account()
    other = SigningKey.generate()
    assert {:error, :invalid_rotation_key} = Registrations.stage(ctx.did, ctx.operation, other)
    assert {:ok, _} = Repositories.set_status(ctx.did, :active)

    assert {:error, :invalid_registration_account} =
             Registrations.stage(ctx.did, ctx.operation, ctx.rotation)

    assert {:ok, _} = Repositories.set_status(ctx.did, :deactivated)
    Repo.update_all(Profile, set: [handle: "wrong.example.com"])

    assert {:error, :invalid_registration_account} =
             Registrations.stage(ctx.did, ctx.operation, ctx.rotation)

    Repo.update_all(Profile, set: [handle: "alice.example.com"])
    Repo.delete_all(Atoll.Repositories.EncryptedKey)
    assert {:error, :key_not_found} = Registrations.stage(ctx.did, ctx.operation, ctx.rotation)
    refute Repo.get(Registration, ctx.did)
  end

  test "ambiguous submission leaves a durable retry with exactly the same operation" do
    ctx = account()
    assert {:ok, _} = Registrations.stage(ctx.did, ctx.operation, ctx.rotation)
    envelope = Repo.get!(Registration, ctx.did).rotation_envelope

    Req.Test.expect(__MODULE__, fn conn ->
      assert_post(conn, ctx.operation)
      Req.Test.transport_error(conn, :timeout)
    end)

    Req.Test.expect(__MODULE__, &Plug.Conn.send_resp(&1, 404, ""))

    assert {:error, :plc_unavailable} =
             Registrations.submit(ctx.did, plug: {Req.Test, __MODULE__})

    assert is_nil(Repo.get!(Registration, ctx.did).confirmed_at)

    for _ <- 1..2 do
      previous_confirmation = Repo.get!(Registration, ctx.did).confirmed_at

      Req.Test.expect(__MODULE__, fn conn ->
        assert_post(conn, ctx.operation)
        Plug.Conn.send_resp(conn, 400, "already exists")
      end)

      Req.Test.expect(__MODULE__, &Req.Test.json(&1, ctx.operation))
      assert {:ok, %{did: did}} = Registrations.submit(ctx.did, plug: {Req.Test, __MODULE__})
      assert did == ctx.did
      row = Repo.get!(Registration, ctx.did)
      assert row.confirmed_at
      if previous_confirmation, do: assert(row.confirmed_at == previous_confirmation)
      assert row.rotation_envelope == envelope
      assert Repo.get!(Head, ctx.did).status == :deactivated
    end
  end

  test "operation tampering fails before network and encrypted key binds DID, CID and public key" do
    ctx = account()
    other = account("bob.example.com")
    assert {:ok, _} = Registrations.stage(ctx.did, ctx.operation, ctx.rotation)
    assert {:ok, _} = Registrations.stage(other.did, other.operation, other.rotation)
    row = Repo.get!(Registration, ctx.did)
    other_row = Repo.get!(Registration, other.did)

    Repo.update_all(from(r in Registration, where: r.did == ^ctx.did),
      set: [rotation_envelope: other_row.rotation_envelope]
    )

    assert {:error, :key_decryption_failed} = Registrations.rotation_key(ctx.did)

    Repo.update_all(from(r in Registration, where: r.did == ^ctx.did),
      set: [rotation_envelope: row.rotation_envelope, cid: other.cid]
    )

    assert {:error, :key_decryption_failed} = Registrations.rotation_key(ctx.did)
    assert {:error, :invalid_plc_operation} = Registrations.submit(ctx.did)

    Repo.update_all(from(r in Registration, where: r.did == ^ctx.did),
      set: [cid: ctx.cid, operation: Map.put(ctx.operation, "sig", "bad")]
    )

    assert {:error, :invalid_plc_operation} = Registrations.submit(ctx.did)
  end

  test "missing master key and changed master key fail closed; account deletion removes journal" do
    ctx = account()
    assert {:ok, _} = Registrations.stage(ctx.did, ctx.operation, ctx.rotation)
    Application.delete_env(:atoll, :key_encryption_key)
    assert {:error, :key_vault_unconfigured} = Registrations.rotation_key(ctx.did)
    assert {:error, :key_vault_unconfigured} = Registrations.submit(ctx.did)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    assert {:error, :key_decryption_failed} = Registrations.rotation_key(ctx.did)
    assert {:error, :key_decryption_failed} = Registrations.submit(ctx.did)
    Repo.delete!(Repo.get!(Head, ctx.did))
    refute Repo.get(Registration, ctx.did)
    assert {:error, :registration_not_found} = Registrations.rotation_key(ctx.did)
    assert {:error, :registration_not_found} = Registrations.submit(ctx.did)
  end

  defp assert_post(conn, operation) do
    assert conn.method == "POST"
    {:ok, body, _} = Plug.Conn.read_body(conn)
    assert Jason.decode!(body) == operation
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
