defmodule Atoll.RepositoryKeyRecoveryTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Commit, KeyVault, Repositories, SigningKey, Storage}
  alias Atoll.Repositories.{EncryptedKey, Events, Revision}
  @did "did:web:recover.example.com"
  @path "com.example.record/one"

  setup do
    for name <- [:key_encryption_key, :previous_key_encryption_keys, :repository_quota] do
      prior = Application.fetch_env(:atoll, name)

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:atoll, name, value)
          :error -> Application.delete_env(:atoll, name)
        end
      end)
    end

    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:atoll, :previous_key_encryption_keys, [])
    old = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, old)
    {:ok, _} = KeyVault.store(@did, old)

    {:ok, head} =
      Repositories.apply_managed_writes(@did, [
        {:put, @path, %{"$type" => "com.example.record", "text" => "preserved"}}
      ])

    {:ok, record} = Repositories.get_record(@did, @path)
    %{old: old, new: SigningKey.generate(:p256), head: head, record: record}
  end

  test "lost master key permits independently authorized restoration while ordinary rotation fails",
       c do
    Application.put_env(:atoll, :key_encryption_key, :crypto.strong_rand_bytes(32))
    assert {:error, :key_decryption_failed} = KeyVault.fetch(@did)

    assert {:error, :key_decryption_failed} =
             Repositories.rotate_signing_key(@did, c.new, c.head.head)

    seq = Events.latest_seq()
    assert {:ok, updated} = Repositories.recover_signing_key(@did, c.new, c.head.head)
    assert KeyVault.fetch(@did) == {:ok, c.new}
    {:ok, bytes} = Storage.get_block(updated.head)
    assert {:ok, commit} = Commit.verify(bytes, @did, c.new.curve, c.new.public)
    {:ok, old_bytes} = Storage.get_block(c.head.head)
    {:ok, old_commit} = Commit.verify(old_bytes, @did, c.old.curve, c.old.public)
    assert commit["data"] == old_commit["data"]
    assert updated.rev > c.head.rev
    assert {:ok, [%{kind: :sync}]} = Events.list_after(seq)
    assert Repositories.get_record(@did, @path, c.record.cid) == {:ok, c.record}
    assert Repo.get_by!(Revision, did: @did, rev: c.head.rev).signing_public_key == c.old.public

    assert {:ok, _} =
             Repositories.apply_managed_writes(@did, [
               {:put, @path, %{"$type" => "com.example.record", "text" => "after recovery"}}
             ])
  end

  test "missing custody can be repaired with the original key without a new commit or event", c do
    Repo.delete!(Repo.get!(EncryptedKey, @did))
    seq = Events.latest_seq()
    assert {:ok, head} = Repositories.recover_signing_key(@did, c.old, c.head.head)
    assert head == c.head
    assert KeyVault.fetch(@did) == {:ok, c.old}
    envelope = Repo.get!(EncryptedKey, @did).envelope
    assert {:ok, ^head} = Repositories.recover_signing_key(@did, c.old, head.head)
    assert Repo.get!(EncryptedKey, @did).envelope == envelope
    assert Events.latest_seq() == seq
  end

  test "same-key restoration repairs a corrupt envelope and preserves deactivation", c do
    corrupt!()
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    seq = Events.latest_seq()

    assert {:ok, %{status: :deactivated} = head} =
             Repositories.recover_signing_key(@did, c.old, c.head.head)

    assert head.head == c.head.head
    assert KeyVault.fetch(@did) == {:ok, c.old}
    assert Events.latest_seq() == seq
  end

  test "quota failure rolls back newly created custody, head, history and event", c do
    Repo.delete!(Repo.get!(EncryptedKey, @did))
    Application.put_env(:atoll, :repository_quota, max_bytes: 0)
    count = Repo.aggregate(Revision, :count)
    seq = Events.latest_seq()

    assert {:error, :repository_quota_exceeded} =
             Repositories.recover_signing_key(@did, c.new, c.head.head)

    assert Repo.get(EncryptedKey, @did) == nil
    assert Repositories.get_head(@did) == {:ok, c.head}
    assert Repo.aggregate(Revision, :count) == count
    assert Events.latest_seq() == seq
  end

  test "stale heads, invalid key pairs and suspension cannot overwrite corrupt custody", c do
    corrupt!()
    envelope = Repo.get!(EncryptedKey, @did).envelope
    assert {:error, :invalid_swap} = Repositories.recover_signing_key(@did, c.new, <<0>>)

    assert {:error, :invalid_key} =
             Repositories.recover_signing_key(@did, %{c.new | public: c.old.public}, c.head.head)

    {:ok, _} = Repositories.set_status(@did, :suspended)

    assert {:error, {:repo_inactive, :suspended}} =
             Repositories.recover_signing_key(@did, c.new, c.head.head)

    assert Repo.get!(EncryptedKey, @did).envelope == envelope
  end

  test "corrupt record bodies are rejected before repairing custody", c do
    corrupt!()
    envelope = Repo.get!(EncryptedKey, @did).envelope

    Repo.get!(Atoll.Storage.Block, c.record.cid)
    |> Ecto.Changeset.change(data: <<0>>)
    |> Repo.update!()

    assert {:error, :invalid_repository} =
             Repositories.recover_signing_key(@did, c.new, c.head.head)

    assert Repo.get!(EncryptedKey, @did).envelope == envelope
    assert Repositories.get_head(@did) == {:ok, c.head}
  end

  test "restoration requires an active master key and rolls back with caller recovery state", c do
    corrupt!()
    envelope = Repo.get!(EncryptedKey, @did).envelope

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, _} = Repositories.recover_signing_key(@did, c.new, c.head.head)
               Repo.rollback(:cancelled)
             end)

    assert Repo.get!(EncryptedKey, @did).envelope == envelope
    assert Repositories.get_head(@did) == {:ok, c.head}
    Application.delete_env(:atoll, :key_encryption_key)
    assert {:error, _} = Repositories.recover_signing_key(@did, c.new, c.head.head)
    assert Repo.get!(EncryptedKey, @did).envelope == envelope
  end

  defp corrupt! do
    Repo.get!(EncryptedKey, @did)
    |> Ecto.Changeset.change(envelope: :binary.copy(<<0>>, 61))
    |> Repo.update!(log: false)
  end
end
