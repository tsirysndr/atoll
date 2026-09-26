defmodule Atoll.RepositoryKeyRotationTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Commit, KeyVault, Repo, Repositories, SigningKey, Storage}
  alias Atoll.Repositories.{EncryptedKey, Events, Revision}
  @did "did:plc:localrotation"
  @path "com.example.record/one"

  setup do
    before = Application.fetch_env(:atoll, :key_encryption_key)
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      case before do
        {:ok, key} -> Application.put_env(:atoll, :key_encryption_key, key)
        :error -> Application.delete_env(:atoll, :key_encryption_key)
      end
    end)

    old = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, old)
    {:ok, _} = KeyVault.store(@did, old)

    {:ok, head} =
      Repositories.apply_managed_writes(@did, [{:put, @path, %{"$type" => "com.example.record"}}])

    %{old: old, head: head, new: SigningKey.generate(:p256)}
  end

  test "atomically replaces the vault key and publishes an unchanged tree with a new signature",
       c do
    {:ok, record} = Repositories.get_record(@did, @path)
    old_envelope = Repo.get!(EncryptedKey, @did).envelope
    seq = Events.latest_seq()
    assert {:ok, updated} = Repositories.rotate_signing_key(@did, c.new, c.head.head)
    assert updated.rev > c.head.rev
    assert KeyVault.fetch(@did) == {:ok, c.new}
    assert Repo.get!(EncryptedKey, @did).envelope != old_envelope
    assert {:ok, bytes} = Storage.get_block(updated.head)
    assert {:ok, commit} = Commit.verify(bytes, @did, c.new.curve, c.new.public)
    {:ok, old_bytes} = Storage.get_block(c.head.head)
    {:ok, old_commit} = Commit.verify(old_bytes, @did, c.old.curve, c.old.public)
    assert commit["data"] == old_commit["data"]
    assert Repositories.get_record(@did, @path, record.cid) == {:ok, record}
    assert Repo.get_by!(Revision, did: @did, rev: c.head.rev).signing_public_key == c.old.public
    assert {:ok, [%{kind: :sync} = event]} = Events.list_after(seq)
    assert {:ok, ^updated} = Repositories.rotate_signing_key(@did, c.new, updated.head)
    assert Events.latest_seq() == event.seq

    assert {:ok, _} =
             Repositories.apply_managed_writes(@did, [
               {:put, @path, %{"$type" => "com.example.record", "text" => "new key"}}
             ])
  end

  test "stale expected heads and mismatched private keys cannot mutate the vault", c do
    envelope = Repo.get!(EncryptedKey, @did).envelope
    assert {:error, :invalid_swap} = Repositories.rotate_signing_key(@did, c.new, <<0>>)

    assert {:error, :invalid_key} =
             Repositories.rotate_signing_key(@did, %{c.new | public: c.old.public}, c.head.head)

    assert Repo.get!(EncryptedKey, @did).envelope == envelope
    assert Repositories.get_head(@did) == {:ok, c.head}
  end

  test "quota failure rolls back key, commit and event publication", c do
    prior = Application.fetch_env(:atoll, :repository_quota)

    on_exit(fn ->
      case prior do
        {:ok, config} -> Application.put_env(:atoll, :repository_quota, config)
        :error -> Application.delete_env(:atoll, :repository_quota)
      end
    end)

    Application.put_env(:atoll, :repository_quota, max_bytes: 0)
    envelope = Repo.get!(EncryptedKey, @did).envelope
    seq = Events.latest_seq()

    assert {:error, :repository_quota_exceeded} =
             Repositories.rotate_signing_key(@did, c.new, c.head.head)

    assert KeyVault.fetch(@did) == {:ok, c.old}
    assert Repo.get!(EncryptedKey, @did).envelope == envelope
    assert Repositories.get_head(@did) == {:ok, c.head}
    assert Events.latest_seq() == seq
  end

  test "preserves deactivation and refuses an unreadable current vault", c do
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert {:ok, updated} = Repositories.rotate_signing_key(@did, c.new, c.head.head)
    assert updated.status == :deactivated

    Repo.get!(EncryptedKey, @did)
    |> Ecto.Changeset.change(envelope: :binary.copy(<<0>>, 61))
    |> Repo.update!(log: false)

    assert {:error, :key_decryption_failed} =
             Repositories.rotate_signing_key(@did, c.old, updated.head)

    assert Repositories.get_head(@did) == {:ok, updated}
  end
end
