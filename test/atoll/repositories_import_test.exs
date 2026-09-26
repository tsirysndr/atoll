defmodule Atoll.RepositoriesImportTest do
  use Atoll.DataCase, async: true
  alias Atoll.{CAR, CBOR, CID, Commit, MST, Repositories, SigningKey, Storage, TID}
  alias Atoll.Repositories.Snapshot
  alias Atoll.Storage.Block
  alias Atoll.CBOR.Link
  @did "did:plc:example"
  @path "com.example.record/self"

  setup do
    key = SigningKey.generate()
    {:ok, head} = Repositories.create(@did, key)
    %{key: key, head: head}
  end

  test "imports a complete signed snapshot and exports identical reachable bytes", %{
    key: key,
    head: head
  } do
    external = CID.create("external blob", :raw)

    record = %{
      "$type" => "com.example.record",
      "text" => "imported",
      "ref" => %Link{cid: external}
    }

    {archive, commit, blocks} = archive(key, head.rev, %{@path => record})
    assert {:ok, imported} = Repositories.import_archive(@did, archive, head.head)
    assert imported.head == commit.cid
    assert {:ok, %{value: value}} = Repositories.get_record(@did, @path)
    assert value["text"] == "imported"
    assert value["ref"] == %{"$link" => CID.to_base32(external)}
    assert {:ok, exported} = Repositories.export(@did)
    assert {:ok, %{roots: [root], blocks: ^blocks}} = CAR.decode(exported)
    assert root == commit.cid
    assert Storage.get_block(external) == {:error, :not_found}
    count = Repo.aggregate(Block, :count)
    assert Repositories.import_archive(@did, archive, imported.head) == {:ok, imported}
    assert Repo.aggregate(Block, :count) == count
  end

  test "replaces old records and ignores unreferenced blocks", %{key: key} do
    value = %{"$type" => "com.example.record"}
    {:ok, prior} = Repositories.apply_writes(@did, [{:put, @path, value}], key)
    {_, commit, blocks} = archive(key, prior.rev, %{})
    extra = CID.create("not part of the repository", :raw)
    {:ok, car} = CAR.encode([commit.cid], Map.put(blocks, extra, "not part of the repository"))
    assert {:ok, imported} = Repositories.import_archive(@did, car, prior.head)
    assert imported.head == commit.cid
    assert Repositories.get_record(@did, @path) == {:error, :not_found}
    assert Storage.get_block(extra) == {:error, :not_found}
  end

  test "stale heads, older revisions and conflicting equal revisions do not overwrite data", %{
    key: key,
    head: head
  } do
    value = %{"$type" => "com.example.record", "text" => "local"}
    {car, _, _} = archive(key, head.rev, %{})
    {:ok, changed} = Repositories.apply_writes(@did, [{:put, @path, value}], key)
    assert Repositories.import_archive(@did, car, head.head) == {:error, :invalid_swap}
    assert {:ok, old} = Repositories.export(@did)
    {:ok, latest} = Repositories.apply_writes(@did, [{:delete, @path}], key)
    assert Repositories.import_archive(@did, old, latest.head) == {:error, :stale_revision}
    {equal, _, _} = archive(key, changed.rev, %{@path => value}, rev: latest.rev)
    assert Repositories.import_archive(@did, equal, latest.head) == {:error, :stale_revision}
    assert Repositories.get_head(@did) == {:ok, latest}
    assert Repositories.get_record(@did, @path) == {:error, :not_found}
  end

  test "rejects missing nodes and record blocks even if they exist in local storage", %{
    key: key,
    head: head
  } do
    value = %{"$type" => "com.example.record"}
    {_, commit, blocks} = archive(key, head.rev, %{@path => value})
    for {cid, bytes} <- blocks, do: Storage.put_block(cid, bytes)

    for missing <- Map.keys(blocks) do
      {:ok, incomplete} = CAR.encode([commit.cid], Map.delete(blocks, missing))

      assert Repositories.import_archive(@did, incomplete, head.head) ==
               {:error, :invalid_snapshot}
    end

    assert Repositories.get_head(@did) == {:ok, head}
  end

  test "rejects wrong signer, identity, future revisions and invalid records without writes", %{
    key: key,
    head: head
  } do
    count = Repo.aggregate(Block, :count)
    future = TID.encode((System.system_time(:microsecond) + 600_000_000) * 1024)

    bad_cases = [
      archive(SigningKey.generate(), head.rev, %{}),
      archive(key, head.rev, %{}, did: "did:plc:other"),
      archive(key, head.rev, %{}, rev: future),
      archive(key, head.rev, %{@path => %{"$type" => "com.example.wrong"}}),
      archive(key, head.rev, %{@path => [1, 2]}),
      archive(key, head.rev, %{
        @path => %{"$type" => "com.example.record", "text" => :binary.copy("x", 1_000_000)}
      })
    ]

    for {car, _, _} <- bad_cases do
      assert Repositories.import_archive(@did, car, head.head) == {:error, :invalid_snapshot}
      assert Repo.aggregate(Block, :count) == count
      assert Repositories.get_head(@did) == {:ok, head}
    end
  end

  test "supports both curves and requires a DAG-CBOR commit root", %{head: head} do
    for curve <- [:p256, :k256] do
      key = SigningKey.generate(curve)
      {car, commit, blocks} = archive(key, head.rev, %{})
      assert {:ok, snapshot} = Snapshot.decode(car, @did, curve, key.public)
      assert snapshot.head == commit.cid
      raw = CID.create(commit.bytes, :raw)
      {:ok, invalid} = CAR.encode([raw], Map.put(blocks, raw, commit.bytes))
      assert Snapshot.decode(invalid, @did, curve, key.public) == {:error, :invalid_snapshot}
      {:ok, no_root} = CAR.encode([], blocks)
      assert Snapshot.decode(no_root, @did, curve, key.public) == {:error, :invalid_snapshot}
    end
  end

  defp archive(key, previous, values, opts \\ []) do
    records =
      Map.new(values, fn {path, value} ->
        bytes = CBOR.encode!(value)
        {path, {CID.create(bytes, :dag_cbor), bytes}}
      end)

    {:ok, tree} = MST.new(Map.new(records, fn {path, {cid, _}} -> {path, cid} end))
    {:ok, next} = TID.next(previous)
    rev = Keyword.get(opts, :rev, next)
    {:ok, commit} = Commit.create(Keyword.get(opts, :did, @did), tree.root, rev, key)

    blocks =
      records
      |> Map.values()
      |> Map.new()
      |> Map.merge(tree.blocks)
      |> Map.put(commit.cid, commit.bytes)

    {:ok, car} = CAR.encode([commit.cid], blocks)
    {car, commit, blocks}
  end
end
