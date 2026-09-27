defmodule Atoll.RepositoriesTest do
  use Atoll.DataCase, async: true
  alias Atoll.{CAR, Commit, MST, Repositories, SigningKey, Storage, TID}
  alias Atoll.Repositories.Head
  alias Atoll.Storage.Block

  @did "did:plc:example"
  @path "com.example.record/self"
  @value %{"$type" => "com.example.record", "text" => "hello"}

  setup do
    key = SigningKey.generate()
    {:ok, head} = Repositories.create(@did, key)
    %{key: key, head: head}
  end

  test "creates an empty signed repository and rolls back duplicate creation", %{
    key: key,
    head: head
  } do
    assert Repositories.get_head(@did) == {:ok, head}
    count = Repo.aggregate(Block, :count)
    assert Repositories.create(@did, key) == {:error, :already_exists}
    assert Repo.aggregate(Block, :count) == count
    assert Repositories.get_head(@did) == {:ok, head}
    assert {:ok, bytes} = Storage.get_block(head.head)
    assert {:ok, commit} = Commit.verify(bytes, @did, key.curve, key.public)
    {:ok, empty} = MST.new()
    assert commit["data"].cid == empty.root
  end

  test "atomically creates, replaces, deletes and exports records", %{key: key, head: initial} do
    assert {:ok, created} =
             Repositories.apply_writes(@did, [{:create, @path, @value}], key,
               swap_commit: initial.head
             )

    assert created.rev > initial.rev
    assert {:ok, record} = Repositories.get_record(@did, @path)
    assert record.value == @value
    assert record.uri == "at://#{@did}/#{@path}"

    assert {:ok, archive} = Repositories.export(@did)
    assert {:ok, %{roots: [root], blocks: blocks}} = CAR.decode(archive)
    assert root == created.head
    assert {:ok, commit} = Commit.verify(blocks[root], @did, key.curve, key.public)
    assert {:ok, tree} = MST.load(commit["data"].cid, blocks)
    assert tree.records == %{@path => record.cid}
    assert Map.has_key?(blocks, record.cid)

    changed = Map.put(@value, "text", "updated")
    assert {:ok, updated} = Repositories.apply_writes(@did, [{:put, @path, changed}], key)
    assert updated.rev > created.rev
    assert {:ok, %{value: ^changed}} = Repositories.get_record(@did, @path)
    assert {:ok, deleted} = Repositories.apply_writes(@did, [{:delete, @path}], key)
    assert deleted.rev > updated.rev
    assert Repositories.get_record(@did, @path) == {:error, :not_found}
    assert {:ok, bytes} = Storage.get_block(deleted.head)
    assert {:ok, commit} = Commit.verify(bytes, @did, key.curve, key.public)
    {:ok, empty} = MST.new()
    assert commit["data"].cid == empty.root
  end

  test "failed batches and stale swaps leave records, blocks and head unchanged", %{
    key: key,
    head: initial
  } do
    {:ok, head} = Repositories.apply_writes(@did, [{:create, @path, @value}], key)
    count = Repo.aggregate(Block, :count)
    other = "com.example.record/other"

    assert Repositories.apply_writes(@did, [{:put, other, @value}, {:create, @path, @value}], key) ==
             {:error, :record_exists}

    assert Repositories.apply_writes(@did, [{:delete, @path}], key, swap_commit: initial.head) ==
             {:error, :invalid_swap}

    assert Repositories.get_head(@did) == {:ok, head}
    assert Repositories.get_record(@did, other) == {:error, :not_found}
    assert {:ok, _} = Repositories.get_record(@did, @path)
    assert Repo.aggregate(Block, :count) == count
  end

  test "separates repositories and refuses mismatched signing keys", %{key: key, head: head} do
    other_key = SigningKey.generate(:p256)
    other_did = "did:plc:other"
    assert {:ok, _} = Repositories.create(other_did, other_key)
    assert {:ok, _} = Repositories.apply_writes(other_did, [{:put, @path, @value}], other_key)
    assert Repositories.get_record(@did, @path) == {:error, :not_found}

    assert Repositories.apply_writes(@did, [{:put, @path, @value}], other_key) ==
             {:error, :invalid_key}

    forged = %{key | private: SigningKey.generate().private}

    assert Repositories.apply_writes(@did, [{:put, @path, @value}], forged) ==
             {:error, :invalid_key}

    assert Repositories.get_head(@did) == {:ok, head}

    assert Repositories.apply_writes("did:plc:missing", [{:delete, @path}], key) ==
             {:error, :not_found}
  end

  test "revisions advance even when the previous revision is ahead of the clock", %{
    key: key,
    head: head
  } do
    future = TID.encode((System.system_time(:microsecond) + 60_000_000) * 1024)
    head |> Ecto.Changeset.change(rev: future) |> Repo.update!()
    assert {:ok, next} = Repositories.apply_writes(@did, [{:put, @path, @value}], key)
    assert next.rev > future
    assert Repo.get!(Head, @did).rev == next.rev
  end

  test "mixed mutations retain canonical membership and exact prior event values", c do
    paths = for n <- 1..300, do: "com.example.record/r#{n}"
    [first_path, second_path | _] = paths

    for batch <- Enum.chunk_every(paths, 200) do
      assert {:ok, _} =
               Repositories.apply_writes(@did, Enum.map(batch, &{:put, &1, @value}), c.key)
    end

    {:ok, old} = Repositories.get_record(@did, first_path)
    seq = Atoll.Repositories.Events.latest_seq()
    changed = Map.put(@value, "text", "updated")

    operations = [
      {:delete, first_path},
      {:put, second_path, changed},
      {:create, "com.example.record/new", @value},
      {:delete, "com.example.record/absent"}
    ]

    assert {:ok, head} = Repositories.apply_writes(@did, operations, c.key)
    {:ok, new} = Repositories.get_record(@did, second_path)

    expected =
      Map.new(paths, &{&1, old.cid})
      |> Map.delete(first_path)
      |> Map.put(second_path, new.cid)
      |> Map.put("com.example.record/new", old.cid)

    {:ok, tree} = MST.new(expected)
    {:ok, commit} = Storage.get_node(head.head)
    assert commit["data"].cid == tree.root
    revision = Repo.get_by!(Atoll.Repositories.Revision, did: @did, rev: head.rev)
    cids = MapSet.new([head.head | Map.keys(tree.blocks) ++ Map.values(expected)])
    assert MapSet.new(revision.blocks) == cids
    assert length(revision.blocks) == MapSet.size(cids)
    assert {:ok, [event]} = Atoll.Repositories.Events.list_after(seq)

    assert Enum.map(event.payload["ops"], &{&1["action"], &1["prev"]}) == [
             {"delete", %Atoll.CBOR.Link{cid: old.cid}},
             {"update", %Atoll.CBOR.Link{cid: old.cid}},
             {"create", nil}
           ]
  end

  test "damaged persisted nodes abort rebuilt writes without publishing partial state", c do
    {:ok, prior} = Repositories.apply_writes(@did, [{:put, @path, @value}], c.key)
    {:ok, commit} = Storage.get_node(prior.head)

    Repo.get!(Block, commit["data"].cid)
    |> Ecto.Changeset.change(data: "corrupt")
    |> Repo.update!()

    seq = Atoll.Repositories.Events.latest_seq()
    count = Repo.aggregate(Block, :count)

    assert Repositories.apply_writes(@did, [{:put, @path, @value}], c.key) ==
             {:error, :invalid_repository}

    assert Repositories.get_head(@did) == {:ok, prior}
    assert Repo.aggregate(Block, :count) == count
    assert Atoll.Repositories.Events.latest_seq() == seq
  end

  test "rejects duplicate paths, mismatched types, invalid values and oversized records", %{
    key: key
  } do
    assert Repositories.apply_writes(@did, [{:delete, @path}, {:put, @path, @value}], key) ==
             {:error, :duplicate_path}

    for ops <- [[], List.duplicate({:delete, @path}, 201)] do
      assert Repositories.apply_writes(@did, ops, key) == {:error, :invalid_writes}
    end

    for op <- [
          {:delete, "bad"},
          {:put, @path, %{}},
          {:put, @path, %{"$type" => "com.example.other"}},
          {:put, @path, Map.put(@value, "number", 1.2)},
          {:put, @path, Map.put(@value, "text", :binary.copy("a", 1_000_000))}
        ] do
      assert Repositories.apply_writes(@did, [op], key) == {:error, :invalid_record}
    end
  end
end
