defmodule Atoll.RepositoryQuotaTest do
  use Atoll.DataCase, async: false
  alias Atoll.{Blobs, CAR, Commit, MST, Repositories, SigningKey, Storage, TID}
  alias Atoll.Repositories.{Events, Head, Quota, Revision}
  alias Atoll.Storage.Block
  @did "did:plc:repositoryquota"
  @path "com.example.record/one"

  setup do
    prior = Application.fetch_env(:atoll, :repository_quota)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:atoll, :repository_quota, value)
        :error -> Application.delete_env(:atoll, :repository_quota)
      end
    end)

    Application.delete_env(:atoll, :repository_quota)
    key = SigningKey.generate()
    {:ok, head} = Repositories.create(@did, key)
    %{key: key, head: head}
  end

  test "usage counts distinct CIDs across all revisions, excluding blobs and orphan bytes", c do
    value = %{"$type" => "com.example.record", "text" => "same"}

    for _ <- 1..3,
        do:
          assert(match?({:ok, _}, Repositories.apply_writes(@did, [{:put, @path, value}], c.key)))

    {:ok, _} = Blobs.stage(@did, "not repository quota", "text/plain")
    {:ok, _} = Storage.put_node(%{"orphan" => "not owned"})
    inventories = Repo.all(from r in Revision, where: r.did == ^@did, select: r.blocks)
    cids = List.flatten(inventories) |> Enum.uniq()

    sizes =
      Repo.all(
        from b in Block, where: b.cid in ^cids, select: fragment("octet_length(?)", b.data)
      )

    assert length(cids) < length(List.flatten(inventories))
    assert Quota.usage(@did) == %{count: length(cids), bytes: Enum.sum(sizes)}
    assert Repo.aggregate(Block, :count) > length(cids)
    before = Quota.usage(@did)
    {:ok, _} = Repositories.apply_writes(@did, [{:delete, @path}], c.key)
    assert Quota.usage(@did).bytes > before.bytes
  end

  test "count and byte limits roll back heads, records, blocks and events", c do
    used = Quota.usage(@did)
    blocks = Repo.aggregate(Block, :count)
    seq = Events.latest_seq()

    for limit <- [[max_count: used.count], [max_bytes: used.bytes]] do
      Application.put_env(:atoll, :repository_quota, limit)

      assert {:error, :repository_quota_exceeded} =
               Repositories.apply_writes(
                 @did,
                 [{:put, @path, %{"$type" => "com.example.record", "text" => "too large"}}],
                 c.key
               )

      assert Repositories.get_head(@did) == {:ok, c.head}
      assert Repositories.get_record(@did, @path) == {:error, :not_found}
      assert Quota.usage(@did) == used
      assert Repo.aggregate(Block, :count) == blocks
      assert Events.latest_seq() == seq
    end
  end

  test "quota failure restores blob references and cancels queued withdrawal", c do
    {:ok, blob} = Blobs.stage(@did, "referenced blob", "text/plain")
    value = %{"$type" => "com.example.record", "blob" => blob}
    {:ok, head} = Repositories.apply_writes(@did, [{:put, @path, value}], c.key)
    used = Quota.usage(@did)
    Application.put_env(:atoll, :repository_quota, max_bytes: used.bytes)

    assert {:error, :repository_quota_exceeded} =
             Repositories.apply_writes(@did, [{:delete, @path}], c.key)

    assert Repositories.get_head(@did) == {:ok, head}
    assert {:ok, %{value: ^value}} = Repositories.get_record(@did, @path)
    assert Repo.aggregate(Atoll.Blobs.Reference, :count) == 1
    assert Repo.aggregate(Atoll.Blobs.CleanupJob, :count) == 0
  end

  test "imports enforce quota atomically while identical retries can succeed after a limit decrease",
       c do
    {:ok, tree} = MST.new()
    {:ok, rev} = TID.next(c.head.rev)
    {:ok, commit} = Commit.create(@did, tree.root, rev, c.key)
    {:ok, car} = CAR.encode([commit.cid], Map.put(tree.blocks, commit.cid, commit.bytes))
    used = Quota.usage(@did)
    Application.put_env(:atoll, :repository_quota, max_count: used.count)

    assert {:error, :repository_quota_exceeded} =
             Repositories.import_archive(@did, car, c.head.head)

    assert Storage.get_block(commit.cid) == {:error, :not_found}
    assert Repositories.get_head(@did) == {:ok, c.head}
    Application.put_env(:atoll, :repository_quota, max_count: used.count + 1)
    assert {:ok, imported} = Repositories.import_archive(@did, car, c.head.head)
    Application.put_env(:atoll, :repository_quota, max_count: 0, max_bytes: 0)
    assert Repositories.import_archive(@did, car, imported.head) == {:ok, imported}
  end

  test "new repositories are charged for shared physical blocks and invalid settings fail closed",
       c do
    # Every account owns its genesis commit and empty tree, even when that tree is already stored.
    Application.put_env(:atoll, :repository_quota, max_count: 1)

    assert {:error, :repository_quota_exceeded} =
             Repositories.create("did:plc:quotarejected", c.key)

    assert is_nil(Repo.get(Head, "did:plc:quotarejected"))
    Application.put_env(:atoll, :repository_quota, max_count: 2)
    assert {:ok, _} = Repositories.create("did:plc:quotaaccepted", c.key)
    assert Quota.usage("did:plc:quotaaccepted").count == 2

    for limits <- [[max_count: -1], [max_bytes: "100"], [max_count: nil]] do
      Application.put_env(:atoll, :repository_quota, limits)

      assert {:error, :invalid_repository_quota} =
               Repositories.apply_writes(
                 @did,
                 [{:put, @path, %{"$type" => "com.example.record"}}],
                 c.key
               )
    end
  end
end
