defmodule Atoll.BlockCleanupTest do
  # Cleanup deliberately times out on the global mutation lock after one second.
  # These success-path tests must not contend with unrelated async repository writes.
  use Atoll.DataCase, async: false
  alias Atoll.{CID, Repositories, SigningKey, Storage}
  alias Atoll.Repositories.{Event, Events, Head, Revision}
  alias Atoll.Storage.{Block, Cleanup}
  @did "did:plc:blockcleanup"
  @path "com.example.record/one"

  test "only old unowned DAG-CBOR blocks are collected in bounded batches" do
    old =
      for n <- 1..3 do
        {:ok, cid} = Storage.put_node(%{"orphan" => n})
        cid
      end

    {:ok, recent} = Storage.put_node(%{"recent" => true})
    raw = CID.create("raw orphan", :raw)
    :ok = Storage.put_block(raw, "raw orphan")
    age(old ++ [raw])
    assert {:ok, 2} = Cleanup.prune(limit: 2)
    assert {:ok, 1} = Cleanup.prune(limit: 2)
    assert {:ok, 0} = Cleanup.prune()
    for cid <- old, do: assert(Storage.get_block(cid) == {:error, :not_found})
    assert {:ok, _} = Storage.get_node(recent)
    assert {:ok, "raw orphan"} = Storage.get_block(raw)
  end

  test "retains complete historical revisions and firehose blocks for inactive repositories" do
    key = SigningKey.generate()
    {:ok, genesis} = Repositories.create(@did, key)

    {:ok, written} =
      Repositories.apply_writes(
        @did,
        [{:create, @path, %{"$type" => "com.example.record", "text" => "old"}}],
        key
      )

    {:ok, _} = Repositories.apply_writes(@did, [{:delete, @path}], key)
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    cids = Repo.all(from r in Revision, select: r.blocks) |> List.flatten() |> Enum.uniq()
    age(cids)
    {:ok, orphan} = Storage.put_node(%{"orphan" => true})
    age([orphan])
    assert {:ok, 1} = Cleanup.prune()
    for cid <- cids, do: assert(match?({:ok, _}, Storage.get_block(cid)))
    assert {:ok, _} = Storage.get_node(genesis.head)
    assert {:ok, _} = Storage.get_node(written.head)
    {:ok, events} = Events.list_after(0)

    for event <- events,
        do: assert(match?({:ok, _}, Atoll.Repositories.EventEncoder.encode(event)))
  end

  test "deleting one repository releases unique blocks while shared history remains usable" do
    key = SigningKey.generate()
    other = "did:plc:otherblockcleanup"
    record = %{"$type" => "com.example.record", "text" => "shared"}

    for did <- [@did, other] do
      {:ok, _} = Repositories.create(did, key)
      {:ok, _} = Repositories.apply_writes(did, [{:create, @path, record}], key)
    end

    left = owned(@did)
    right = owned(other)
    assert MapSet.size(MapSet.intersection(left, right)) > 0
    age(MapSet.to_list(MapSet.union(left, right)))
    remove(@did)
    expected = MapSet.size(MapSet.difference(left, right))
    assert {:ok, ^expected} = Cleanup.prune()
    for cid <- right, do: assert(match?({:ok, _}, Storage.get_block(cid)))
    assert {:ok, _} = Repositories.export(other)
    remove(other)
    remaining = MapSet.size(right)
    assert {:ok, ^remaining} = Cleanup.prune()
    assert Repo.aggregate(Block, :count) == 0
  end

  test "retained revision inventories conservatively protect extra blocks" do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)

    {:ok, head} =
      Repositories.apply_writes(@did, [{:create, @path, %{"$type" => "com.example.record"}}], key)

    # A conservative inventory containing extra references also prevents collection.
    {:ok, pinned} = Storage.put_node(%{"retained" => true})
    revision = Repo.get_by!(Revision, did: @did, rev: head.rev)
    revision |> Ecto.Changeset.change(blocks: [pinned | revision.blocks]) |> Repo.update!()
    age([pinned, head.head])
    assert {:ok, 0} = Cleanup.prune()
    assert {:ok, _} = Storage.get_node(pinned)
  end

  test "rejects unsafe options and cannot run inside another transaction" do
    for opts <- [
          [limit: 0],
          [limit: 1001],
          [limit: "5"],
          [grace_seconds: 3599],
          [grace_seconds: 31_536_001]
        ] do
      assert {:error, :invalid_cleanup_options} = Cleanup.prune(opts)
    end

    assert {:ok, {:error, :cleanup_requires_own_transaction}} =
             Repo.transaction(fn -> Cleanup.prune() end)
  end

  defp owned(did),
    do:
      Repo.all(from r in Revision, where: r.did == ^did, select: r.blocks)
      |> List.flatten()
      |> MapSet.new()

  defp age(cids),
    do:
      Repo.update_all(from(b in Block, where: b.cid in ^cids),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -90_000, :second)]
      )

  defp remove(did) do
    Repo.transaction(fn ->
      Events.lock!()
      Repo.delete_all(from e in Event, where: e.did == ^did)
      Repo.get!(Head, did) |> Repo.delete!()
    end)
  end
end
