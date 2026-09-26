defmodule Atoll.KeyVaultTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Commit, KeyVault, Repositories, SigningKey, Storage}
  alias Atoll.Repositories.EncryptedKey
  alias Atoll.Storage.Block
  @did "did:plc:example"

  setup do
    previous = Application.fetch_env(:atoll, :key_encryption_key)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:atoll, :key_encryption_key, value)
        :error -> Application.delete_env(:atoll, :key_encryption_key)
      end
    end)

    :ok
  end

  test "persists both curves encrypted and signs after loading from PostgreSQL" do
    for curve <- [:p256, :k256] do
      did = @did <> Atom.to_string(curve)
      key = SigningKey.generate(curve)
      {:ok, _} = Repositories.create(did, key)
      assert KeyVault.store(did, key) == {:ok, :stored}
      stored = Repo.get!(EncryptedKey, did)
      assert byte_size(stored.envelope) == 61
      assert :binary.match(stored.envelope, key.private) == :nomatch
      refute inspect(stored) =~ "envelope"
      assert KeyVault.fetch(did) == {:ok, key}
      assert KeyVault.store(did, key) == {:error, :key_exists}
      assert Repo.get!(EncryptedKey, did).envelope == stored.envelope

      assert {:ok, head} =
               Repositories.apply_managed_writes(did, [
                 {:put, "com.example.record/self", %{"$type" => "com.example.record"}}
               ])

      {:ok, bytes} = Storage.get_block(head.head)
      assert {:ok, _} = Commit.verify(bytes, did, curve, key.public)
    end
  end

  test "managed creation is atomic and duplicate creation preserves the original key" do
    assert {:ok, head} = Repositories.create_managed(@did)
    assert {:ok, key} = KeyVault.fetch(@did)
    assert key.public == head.public_key
    assert Repositories.create_managed(@did) == {:error, :already_exists}
    assert KeyVault.fetch(@did) == {:ok, key}
  end

  test "missing or invalid master key fails closed and leaves no repository or blocks" do
    count = Repo.aggregate(Block, :count)

    for invalid <- [nil, "short"] do
      Application.put_env(:atoll, :key_encryption_key, invalid)
      assert Repositories.create_managed(@did) == {:error, :key_vault_unconfigured}
      assert Repositories.get_head(@did) == {:error, :not_found}
      assert Repo.aggregate(Block, :count) == count
      assert KeyVault.fetch(@did) == {:error, :key_vault_unconfigured}
    end
  end

  test "wrong master key and tampered envelopes fail authentication" do
    {:ok, _} = Repositories.create_managed(@did)
    master = Application.fetch_env!(:atoll, :key_encryption_key)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    assert KeyVault.fetch(@did) == {:error, :key_decryption_failed}
    Application.put_env(:atoll, :key_encryption_key, master)
    row = Repo.get!(EncryptedKey, @did)
    # Version, nonce, ciphertext, and tag tampering must all be rejected.
    for index <- [0, 1, 13, 45] do
      <<before::binary-size(index), byte, rest::binary>> = row.envelope
      modified = before <> <<Bitwise.bxor(byte, 1)>> <> rest
      row |> Ecto.Changeset.change(envelope: modified) |> Repo.update!()
      assert KeyVault.fetch(@did) == {:error, :key_decryption_failed}
    end
  end

  test "envelopes cannot be transplanted between repositories even with the same signing key" do
    key = SigningKey.generate()

    for did <- [@did, "did:plc:other"] do
      {:ok, _} = Repositories.create(did, key)
      {:ok, :stored} = KeyVault.store(did, key)
    end

    a = Repo.get!(EncryptedKey, @did)
    b = Repo.get!(EncryptedKey, "did:plc:other")
    assert a.envelope != b.envelope
    b |> Ecto.Changeset.change(envelope: a.envelope) |> Repo.update!()
    assert KeyVault.fetch("did:plc:other") == {:error, :key_decryption_failed}
    assert KeyVault.fetch(@did) == {:ok, key}
  end

  test "rejects a key that does not match the pinned public key" do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    assert KeyVault.store(@did, SigningKey.generate()) == {:error, :invalid_key}
    assert KeyVault.store(@did, %{key | private: <<0::256>>}) == {:error, :invalid_key}
    assert KeyVault.fetch(@did) == {:error, :key_not_found}
    assert KeyVault.store("did:plc:missing", key) == {:error, :not_found}
  end
end
