defmodule Atoll.Repositories.BlockReferenceTest do
  use Atoll.DataCase, async: true
  alias Atoll.{Repositories, SigningKey}
  alias Atoll.Repositories.{BlockReference, Quota, Revision}
  @did "did:plc:blockreferences"

  test "retained revisions count each CID once per revision and match quota inventory" do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    value = %{"$type" => "com.example.record", "text" => "shared"}

    for path <- ["com.example.record/one", "com.example.record/two"] do
      assert {:ok, _} = Repositories.apply_writes(@did, [{:put, path, value}], key)
      assert_index()
    end

    oldest = Repo.one!(from r in Revision, where: r.did == @did, order_by: r.rev, limit: 1)
    oldest |> Ecto.Changeset.change(blocks: oldest.blocks ++ oldest.blocks) |> Repo.update!()
    assert_index()
    assert Enum.any?(Repo.all(BlockReference), &(&1.revision_count > 1))

    %{rows: [[count, bytes]]} =
      Repo.query!(
        """
        SELECT count(*), COALESCE(sum(octet_length(b.data)), 0)::bigint FROM blocks b
        JOIN (SELECT DISTINCT unnest(blocks) AS cid FROM repository_revisions WHERE did = $1) r ON r.cid = b.cid
        """,
        [@did]
      )

    assert Quota.usage(@did) == %{count: count, bytes: bytes}
    Repo.delete!(oldest)
    assert_index()
  end

  test "rolled-back writes and revision replacement roll back index changes" do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    before = Repo.all(BlockReference)

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               {:ok, _} =
                 Repositories.apply_writes(
                   @did,
                   [{:put, "com.example.record/one", %{"$type" => "com.example.record"}}],
                   key
                 )

               assert_index()
               Repo.rollback(:cancelled)
             end)

    assert Repo.all(BlockReference) == before
    revision = Repo.one!(Revision)
    revision |> Ecto.Changeset.change(blocks: []) |> Repo.update!()
    assert Repo.aggregate(BlockReference, :count) == 0
    Repo.one!(Revision) |> Ecto.Changeset.change(blocks: revision.blocks) |> Repo.update!()
    assert Repo.aggregate(BlockReference, :count) > 0
    assert_index()
  end

  test "account deletion cascades its index without affecting shared block owners" do
    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    other = "did:plc:otherblockreferences"
    {:ok, _} = Repositories.create(other, SigningKey.generate())
    other_refs = Repo.all(from r in BlockReference, where: r.did == ^other, order_by: r.cid)
    assert Repo.aggregate(from(r in BlockReference, where: r.did == @did), :count) > 0
    Repo.query!("DELETE FROM repositories WHERE did = $1", [@did])
    assert Repo.aggregate(from(r in BlockReference, where: r.did == @did), :count) == 0

    assert Repo.all(from r in BlockReference, where: r.did == ^other, order_by: r.cid) ==
             other_refs

    assert_index()
  end

  defp assert_index do
    expected =
      Repo.query!("""
      SELECT r.did, b.cid, count(*) FROM repository_revisions r
      CROSS JOIN LATERAL (SELECT DISTINCT unnest(r.blocks) AS cid) b
      GROUP BY r.did, b.cid ORDER BY r.did, b.cid
      """).rows

    actual =
      Repo.all(
        from r in BlockReference,
          order_by: [r.did, r.cid],
          select: [r.did, r.cid, r.revision_count]
      )

    assert actual == expected
  end
end
