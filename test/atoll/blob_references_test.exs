defmodule Atoll.BlobReferencesTest do
  use Atoll.DataCase, async: true
  alias Atoll.{Blobs, CAR, CBOR, CID, Commit, MST, Repositories, SigningKey, TID}
  alias Atoll.Blobs.Reference
  alias Atoll.Repositories.Events
  @did "did:plc:blobreferences"
  @path "com.example.record/one"

  setup do
    key = SigningKey.generate()
    {:ok, head} = Repositories.create(@did, key)
    {:ok, blob} = Blobs.stage(@did, "hello", "text/plain")
    {:ok, cid} = CID.from_base32(blob["ref"]["$link"])
    %{key: key, head: head, blob: blob, cid: cid}
  end

  test "nested references publish once; last deletion withdraws ownership", c do
    assert Blobs.get_public(@did, c.cid) == {:error, :blob_not_found}
    assert Blobs.list_public(@did, 10) == {:ok, %{cids: []}}
    {:ok, _} = write(c, @path, %{"nested" => [c.blob, %{"again" => c.blob}]})
    assert Repo.aggregate(Reference, :count) == 1
    assert {:ok, %{bytes: "hello"}} = Blobs.get_public(@did, c.cid)
    {:ok, _} = write(c, "com.example.record/two", c.blob)
    {:ok, _} = Repositories.apply_writes(@did, [{:delete, @path}], c.key)
    assert {:ok, %{bytes: "hello"}} = Blobs.get_public(@did, c.cid)
    {:ok, _} = Repositories.apply_writes(@did, [{:delete, "com.example.record/two"}], c.key)
    assert Blobs.get_public(@did, c.cid) == {:error, :blob_not_found}
    assert Blobs.get_staged(@did, c.cid) == {:error, :blob_not_found}
  end

  test "moving a reference within a batch preserves ownership", c do
    {:ok, _} = write(c, @path, c.blob)

    {:ok, _} =
      Repositories.apply_writes(
        @did,
        [
          {:delete, @path},
          {:put, "com.example.record/two", record(c.blob)}
        ],
        c.key
      )

    assert {:ok, %{bytes: "hello"}} = Blobs.get_public(@did, c.cid)
  end

  test "invalid or unowned descriptors roll back records, references, and events", c do
    {:ok, initial} = write(c, @path, c.blob)
    seq = Events.latest_seq()

    for invalid <- [
          Map.put(c.blob, "size", 10),
          Map.put(c.blob, "mimeType", "image/png"),
          Map.delete(c.blob, "ref")
        ] do
      assert write(c, @path, invalid) == {:error, :invalid_blob_metadata}
      assert Repositories.get_head(@did) == {:ok, initial}
      assert Events.latest_seq() == seq
      assert {:ok, %{bytes: "hello"}} = Blobs.get_public(@did, c.cid)
    end

    other = "did:plc:foreignblob"
    {:ok, _} = Repositories.create(other, c.key)

    assert Repositories.apply_writes(other, [{:put, @path, record(c.blob)}], c.key) ==
             {:error, :blob_not_found}
  end

  test "lists deduplicated blobs with exclusive cursor and since revision", c do
    {:ok, first} = write(c, @path, c.blob)
    {:ok, other} = Blobs.stage(@did, "other", "text/plain")
    {:ok, second} = write(c, "com.example.record/two", other)
    {:ok, %{cids: [one], cursor: cursor}} = Blobs.list_public(@did, 1)
    {:ok, cursor_cid} = CID.from_base32(cursor)
    {:ok, %{cids: [two]}} = Blobs.list_public(@did, 1, cursor_cid)
    assert MapSet.new([one, two]) == MapSet.new([c.blob["ref"]["$link"], other["ref"]["$link"]])
    assert Blobs.list_public(@did, 10, nil, first.rev) == {:ok, %{cids: [other["ref"]["$link"]]}}
    assert Blobs.list_public(@did, 10, nil, second.rev) == {:ok, %{cids: []}}
  end

  test "imports index missing blobs and replacement removes stale references", c do
    {:ok, prior} = write(c, @path, c.blob)
    missing_cid = CID.create("missing", :raw)

    missing = %{
      "$type" => "blob",
      "ref" => %CBOR.Link{cid: missing_cid},
      "size" => 7,
      "mimeType" => "text/plain"
    }

    bytes = CBOR.encode!(record(missing))
    record_cid = CID.create(bytes, :dag_cbor)
    {:ok, tree} = MST.new(%{@path => record_cid})
    {:ok, rev} = TID.next(prior.rev)
    {:ok, commit} = Commit.create(@did, tree.root, rev, c.key)
    blocks = tree.blocks |> Map.put(record_cid, bytes) |> Map.put(commit.cid, commit.bytes)
    {:ok, car} = CAR.encode([commit.cid], blocks)
    assert {:ok, _} = Repositories.import_archive(@did, car, prior.head)
    assert Blobs.get_public(@did, c.cid) == {:error, :blob_not_found}
    assert Blobs.list_public(@did, 10) == {:ok, %{cids: []}}
    assert {:ok, _} = Blobs.stage(@did, "missing", "text/plain")
    assert {:ok, %{bytes: "missing"}} = Blobs.get_public(@did, missing_cid)
  end

  test "import cleanup spans batches while preserving surviving, moved and never-referenced uploads",
       c do
    items =
      for i <- 1..300 do
        {:ok, blob} = Blobs.stage(@did, "blob #{i}", "text/plain")
        {:ok, cid} = CID.from_base32(blob["ref"]["$link"])
        {"com.example.record/r#{i}", blob, cid}
      end

    writes = Enum.map(items, fn {path, blob, _} -> {:put, path, record(blob)} end)

    prior =
      Enum.reduce(Enum.chunk_every(writes, 200), c.head, fn batch, _ ->
        {:ok, head} = Repositories.apply_writes(@did, batch, c.key)
        head
      end)

    [{same_path, same, same_cid}, {_, moved, moved_cid} | removed] = items
    other = "did:plc:sharedimport"
    {:ok, _} = Repositories.create(other, c.key)
    {:ok, _} = Blobs.stage(other, "blob 3", "text/plain")
    desired = %{same_path => record(same), "com.example.record/moved" => record(moved)}
    assert {:ok, imported} = import_records(c, prior, desired)
    assert Repo.aggregate(Reference, :count) == 2
    assert Enum.all?(Repo.all(Reference), &(&1.rev == imported.rev))
    assert {:ok, %{bytes: "blob 1"}} = Blobs.get_public(@did, same_cid)
    assert {:ok, %{bytes: "blob 2"}} = Blobs.get_public(@did, moved_cid)
    assert {:ok, %{bytes: "hello"}} = Blobs.get_staged(@did, c.cid)
    assert Repo.aggregate(Atoll.Blobs.CleanupJob, :count) == 298

    for {_, _, cid} <- removed,
        do: assert(Blobs.get_staged(@did, cid) == {:error, :blob_not_found})

    {_, _, shared_cid} = hd(removed)
    assert {:ok, %{bytes: "blob 3"}} = Blobs.get_staged(other, shared_cid)
  end

  test "import rollback restores old references, ownership and cleanup jobs", c do
    {:ok, prior} = write(c, @path, c.blob)
    references = Repo.all(Reference)
    seq = Events.latest_seq()

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, _} = import_records(c, prior, %{})
               assert Repo.aggregate(Reference, :count) == 0
               assert Repo.aggregate(Atoll.Blobs.CleanupJob, :count) == 1
               Repo.rollback(:cancelled)
             end)

    assert Repo.all(Reference) == references
    assert Repo.aggregate(Atoll.Blobs.CleanupJob, :count) == 0
    assert {:ok, %{bytes: "hello"}} = Blobs.get_public(@did, c.cid)
    assert Repositories.get_head(@did) == {:ok, prior}
    assert Events.latest_seq() == seq
  end

  defp import_records(c, prior, records) do
    {entries, blocks} =
      Enum.reduce(records, {%{}, %{}}, fn {path, value}, {entries, blocks} ->
        {:ok, node} = Atoll.DataModel.from_json(value)
        bytes = CBOR.encode!(node)
        cid = CID.create(bytes, :dag_cbor)
        {Map.put(entries, path, cid), Map.put(blocks, cid, bytes)}
      end)

    {:ok, tree} = MST.new(entries)
    {:ok, rev} = TID.next(prior.rev)
    {:ok, commit} = Commit.create(@did, tree.root, rev, c.key)
    blocks = blocks |> Map.merge(tree.blocks) |> Map.put(commit.cid, commit.bytes)
    {:ok, archive} = CAR.encode([commit.cid], blocks)
    Repositories.import_archive(@did, archive, prior.head)
  end

  defp record(blob), do: %{"$type" => "com.example.record", "attachment" => blob}

  defp write(c, path, blob),
    do: Repositories.apply_writes(@did, [{:put, path, record(blob)}], c.key)
end
