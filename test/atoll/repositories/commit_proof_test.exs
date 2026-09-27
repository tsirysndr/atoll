defmodule Atoll.Repositories.CommitProofTest do
  use ExUnit.Case, async: true
  alias Atoll.{CID, MST}
  alias Atoll.CBOR.Link
  alias Atoll.Repositories.CommitProof

  test "maximum mixed batches invert to independently reconstructed roots from partial slices" do
    before = Map.new(1..2000, &{path(&1), cid("old#{&1}")})
    {:ok, old} = MST.new(before)

    for offset <- [0, 137, 977] do
      {after_records, ops} =
        Enum.reduce(1..200, {before, []}, fn n, {records, ops} ->
          key = path(n + offset)

          case rem(n, 3) do
            0 ->
              {Map.delete(records, key),
               [
                 %{"action" => "delete", "path" => key, "cid" => nil, "prev" => link(before[key])}
                 | ops
               ]}

            1 ->
              value = cid("new#{n}")

              {Map.put(records, key, value),
               [
                 %{
                   "action" => "update",
                   "path" => key,
                   "cid" => link(value),
                   "prev" => link(before[key])
                 }
                 | ops
               ]}

            2 ->
              key = "com.example.record/new#{n}"
              value = cid("created#{n}")

              {Map.put(records, key, value),
               [%{"action" => "create", "path" => key, "cid" => link(value)} | ops]}
          end
        end)

      {:ok, new} = MST.new(after_records)

      assert {:ok, proof} =
               CommitProof.build(new.root, link(old.root), ops, &Map.fetch(new.blocks, &1))

      assert {:ok, ^proof} =
               CommitProof.build(new.root, link(old.root), ops, &Map.fetch(proof, &1))

      assert CommitProof.build(new.root, link(old.root), tl(ops), &Map.fetch(proof, &1)) ==
               {:error, :invalid_event_blocks}
    end
  end

  test "oversized corrupted bytes are errors rather than a size-based sync fallback" do
    {:ok, empty} = MST.new()

    assert CommitProof.build(empty.root, nil, [], fn _ ->
             {:ok, String.duplicate("x", 1_048_577)}
           end) == {:error, :invalid_event_blocks}

    assert CommitProof.build(empty.root, :bad, [], &Map.fetch(empty.blocks, &1)) ==
             {:error, :invalid_event_blocks}
  end

  defp path(n), do: "com.example.record/r#{n}"
  defp cid(value), do: CID.create(value, :dag_cbor)
  defp link(cid), do: %Link{cid: cid}
end
