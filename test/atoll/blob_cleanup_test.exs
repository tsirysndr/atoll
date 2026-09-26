defmodule Atoll.BlobCleanupTest do
  use Atoll.DataCase, async: true
  alias Atoll.{Blobs, CID, Repositories, SigningKey, Storage}
  alias Atoll.Blobs.{Blob, Cleanup, CleanupJob}
  @did "did:plc:cleanup"
  @path "com.example.record/one"

  setup do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    %{key: key}
  end

  test "expires only old unreferenced uploads and deletes their PostgreSQL bytes", c do
    {old, old_cid} = stage("old")
    {_recent, recent_cid} = stage("recent")
    {used, used_cid} = stage("used")
    {:ok, _} = write(@did, c.key, used)
    age([old_cid, used_cid])
    assert Cleanup.expire_staged() == {:ok, 1}
    assert Blobs.get_staged(@did, old_cid) == {:error, :blob_not_found}
    assert Storage.get_block(old_cid) == {:ok, "old"}
    assert {:ok, %{deleted: 1}} = Cleanup.collect()
    assert Storage.get_block(old_cid) == {:error, :not_found}
    assert {:ok, %{bytes: "used"}} = Blobs.get_public(@did, used_cid)
    assert {:ok, %{bytes: "recent"}} = Blobs.get_staged(@did, recent_cid)
    assert old["size"] == 3
  end

  test "reupload renews the staging grace period and preserves MIME metadata" do
    {blob, cid} = stage("renew")
    age([cid])
    assert Blobs.stage(@did, "renew", "application/octet-stream") == {:ok, blob}
    assert Cleanup.expire_staged() == {:ok, 0}
  end

  test "last reference queues cleanup but another account protects shared bytes", c do
    {blob, cid} = stage("shared")
    other = "did:plc:cleanupother"
    {:ok, _} = Repositories.create(other, c.key)
    {:ok, other_blob} = Blobs.stage(other, "shared", "text/plain")
    {:ok, _} = write(@did, c.key, blob)
    {:ok, _} = write(other, c.key, other_blob)
    {:ok, _} = Repositories.apply_writes(@did, [{:delete, @path}], c.key)
    assert Repo.aggregate(CleanupJob, :count) == 1
    assert {:ok, %{retained: 1, deleted: 0}} = Cleanup.collect()
    assert {:ok, %{bytes: "shared"}} = Blobs.get_public(other, cid)
    {:ok, _} = Repositories.apply_writes(other, [{:delete, @path}], c.key)
    assert {:ok, %{deleted: 1}} = Cleanup.collect()
    assert Storage.get_block(cid) == {:error, :not_found}
  end

  test "reacquired ownership cancels pending cleanup", c do
    {blob, cid} = stage("reacquire")
    {:ok, _} = write(@did, c.key, blob)
    {:ok, _} = Repositories.apply_writes(@did, [{:delete, @path}], c.key)
    {:ok, _} = Blobs.stage(@did, "reacquire", "text/plain")
    assert {:ok, %{retained: 1}} = Cleanup.collect()
    assert {:ok, %{bytes: "reacquire"}} = Blobs.get_staged(@did, cid)
  end

  test "rollback restores references and ownership without leaving a cleanup job", c do
    {blob, cid} = stage("rollback")
    {:ok, _} = write(@did, c.key, blob)

    assert {:error, :abort} =
             Repo.transaction(fn ->
               {:ok, _} = Repositories.apply_writes(@did, [{:delete, @path}], c.key)
               assert Repo.aggregate(CleanupJob, :count) == 1
               assert Cleanup.collect() == {:error, :cleanup_requires_own_transaction}
               Repo.rollback(:abort)
             end)

    assert Repo.aggregate(CleanupJob, :count) == 0
    assert {:ok, %{bytes: "rollback"}} = Blobs.get_public(@did, cid)
  end

  test "enforces minimum grace and bounded batches" do
    for seconds <- [0, 3599, "3600"] do
      assert Cleanup.expire_staged(grace_seconds: seconds) == {:error, :invalid_cleanup_options}
    end

    for limit <- [0, 1001, "1"] do
      assert Cleanup.collect(limit: limit) == {:error, :invalid_cleanup_options}
    end

    {_, a} = stage("one")
    {_, b} = stage("two")
    age([a, b])
    assert Cleanup.expire_staged(limit: 1) == {:ok, 1}
    assert Repo.aggregate(Blob, :count) == 1
  end

  defp stage(bytes) do
    {:ok, blob} = Blobs.stage(@did, bytes, "text/plain")
    {:ok, cid} = CID.from_base32(blob["ref"]["$link"])
    {blob, cid}
  end

  defp age(cids) do
    old = DateTime.add(DateTime.utc_now(), -172_800, :second)
    Repo.update_all(from(b in Blob, where: b.cid in ^cids), set: [staged_at: old])
  end

  defp write(did, key, blob),
    do:
      Repositories.apply_writes(
        did,
        [{:put, @path, %{"$type" => "com.example.record", "blob" => blob}}],
        key
      )
end
