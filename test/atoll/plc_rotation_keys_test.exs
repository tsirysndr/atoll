defmodule Atoll.PLCRotationKeysTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Multikey, Repositories, SigningKey, KeyRewrap}
  alias Atoll.Identity.PLC.{Operation, RotationKey, RotationKeys, Registrations}
  alias Atoll.Repositories.Head

  setup do
    keys = [:key_encryption_key, :previous_key_encryption_keys, :plc_submission_options]
    prior = Map.new(keys, &{&1, Application.fetch_env(:atoll, &1)})
    master = :crypto.strong_rand_bytes(32)
    Application.put_env(:atoll, :key_encryption_key, master)
    Application.put_env(:atoll, :previous_key_encryption_keys, [])

    on_exit(fn ->
      for {key, value} <- prior do
        case value do
          {:ok, val} -> Application.put_env(:atoll, key, val)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    %{master: master}
  end

  test "installs authorized legacy keys on both curves without inventing registration history" do
    for curve <- [:k256, :p256] do
      ctx = account(curve)
      directory(ctx)
      assert {:ok, :installed} = install(ctx, ctx.rotation)
      row = Repo.get!(RotationKey, ctx.did)
      assert byte_size(row.envelope) == 61
      assert :binary.match(row.envelope, ctx.rotation.private) == :nomatch
      refute inspect(row, limit: :infinity) =~ "envelope:"
      assert {:ok, ctx.rotation} == Registrations.rotation_key(ctx.did)
      assert {:ok, :unchanged} = install(ctx, ctx.rotation)
      assert Repo.get!(RotationKey, ctx.did).envelope == row.envelope
      assert {:error, :rotation_key_exists} = install(ctx, ctx.repository)
      refute Repo.get(Atoll.Identity.PLC.Registration, ctx.did)
      {:ok, successor} = Operation.successor(ctx.operation)
      {:ok, key} = Registrations.rotation_key(ctx.did)
      {:ok, next} = Operation.sign(successor, key)
      assert {:ok, _} = Operation.verify_update(ctx.operation, next)
    end
  end

  test "rejects untrusted keys and blocks installation during an open transaction" do
    ctx = account(:k256)
    directory(ctx)
    assert {:error, :invalid_rotation_key} = install(ctx, SigningKey.generate())

    assert {:ok, {:error, :plc_update_inside_transaction}} =
             Repo.transaction(fn -> install(ctx, ctx.rotation) end)

    assert Repo.aggregate(RotationKey, :count) == 0
  end

  test "master-key rewrap preserves the installed key and tampered evidence fails closed", c do
    ctx = account(:k256)
    directory(ctx)
    {:ok, :installed} = install(ctx, ctx.rotation)
    before = Repo.get!(RotationKey, ctx.did)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :previous_key_encryption_keys, [c.master])
    assert {:ok, %{plc: 1}} = KeyRewrap.batch()
    assert Repo.get!(RotationKey, ctx.did).envelope != before.envelope
    Application.put_env(:atoll, :previous_key_encryption_keys, [])
    assert {:ok, ctx.rotation} == Registrations.rotation_key(ctx.did)

    Repo.get!(RotationKey, ctx.did)
    |> Ecto.Changeset.change(verified_cid: "changed")
    |> Repo.update!()

    assert {:error, :key_decryption_failed} = Registrations.rotation_key(ctx.did)
    assert {:error, :key_decryption_failed} = install(ctx, ctx.rotation)
    Repo.delete!(Repo.get!(Head, ctx.did))
    assert Repo.get(RotationKey, ctx.did) == nil
    assert {:error, :registration_not_found} = Registrations.rotation_key(ctx.did)
  end

  test "operator command prints only a public result and sanitizes malformed private-key input" do
    ctx = account(:k256)
    directory(ctx)
    Application.put_env(:atoll, :plc_submission_options, plug: {Req.Test, __MODULE__})
    path = Path.join(System.tmp_dir!(), "atoll-key-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    private = Base.encode64(ctx.rotation.private)
    File.write!(path, Jason.encode!(%{curve: "k256", privateKey: private}))
    File.chmod!(path, 0o600)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Plc.InstallRotationKey.run([ctx.did, path])
      end)

    assert Jason.decode!(output) == %{"did" => ctx.did, "result" => "installed"}
    refute output =~ private
    File.write!(path, ~s({"curve":"k256","privateKey":12345}))

    error =
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Atoll.Plc.InstallRotationKey.run([ctx.did, path])
      end

    refute error.message =~ "12345"
  end

  defp install(ctx, key), do: RotationKeys.install(ctx.did, key, plug: {Req.Test, __MODULE__})

  defp account(curve) do
    repository = SigningKey.generate()
    rotation = SigningKey.generate(curve)
    {:ok, signing} = Multikey.to_did_key(repository.curve, repository.public)
    {:ok, rotating} = Multikey.to_did_key(rotation.curve, rotation.public)

    unsigned = %{
      "type" => "create",
      "signingKey" => signing,
      "recoveryKey" => rotating,
      "handle" => "legacy.example.com",
      "service" => "https://pds.example.com",
      "prev" => nil
    }

    {:ok, sig} = SigningKey.sign(rotation, Atoll.CBOR.encode!(unsigned))
    operation = Map.put(unsigned, "sig", Base.url_encode64(sig, padding: false))
    {:ok, did} = Operation.genesis_did(operation)
    {:ok, cid} = Operation.cid(operation)
    {:ok, _} = Repositories.create(did, repository)

    audit = [
      %{
        "did" => did,
        "cid" => cid,
        "operation" => operation,
        "nullified" => false,
        "createdAt" => "2026-01-01T00:00:00Z"
      }
    ]

    %{did: did, rotation: rotation, repository: repository, operation: operation, audit: audit}
  end

  defp directory(ctx) do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"

      if String.ends_with?(conn.request_path, "/log/audit"),
        do: Req.Test.json(conn, ctx.audit),
        else: Req.Test.json(conn, ctx.operation)
    end)
  end
end
