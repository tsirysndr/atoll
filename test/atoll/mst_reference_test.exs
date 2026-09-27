defmodule Atoll.MSTReferenceTest do
  use ExUnit.Case, async: true
  alias Atoll.{CBOR, CID, MST}
  alias Atoll.Repositories.CommitProof
  @directory Path.expand("../fixtures/mst", __DIR__)
  @reference @directory |> Path.join("reference.json") |> File.read!() |> Jason.decode!()
  @proofs @directory |> Path.join("atoll_proofs.json") |> File.read!() |> Jason.decode!()

  for fixture <- @reference["fixtures"] do
    @fixture fixture
    test "matches reference roots and externally verified proof: #{fixture["name"]}" do
      fixture = @fixture
      records = Map.new(fixture["records"], fn {path, cid} -> {path, cid!(cid)} end)
      before = blocks(fixture["beforeBlocks"])
      after_blocks = blocks(fixture["afterBlocks"])

      ops =
        Enum.map(
          fixture["operations"],
          &(&1
            |> Map.update!("cid", fn x -> link(x) end)
            |> Map.update!("prev", fn x -> link(x) end))
        )

      edits =
        Enum.map(ops, fn op ->
          if op["action"] == "delete",
            do: {:delete, op["path"]},
            else: {:put, op["path"], op["cid"].cid}
        end)

      expected = cid!(fixture["afterRoot"])
      assert {:ok, built} = MST.Builder.build(Enum.sort(records), fn _, _ -> :ok end)
      assert built == cid!(fixture["beforeRoot"])
      assert {:ok, edited} = MST.Editor.apply(built, edits, &Map.fetch(before, &1))
      assert edited.root == expected

      assert {:ok, proof} =
               CommitProof.build(
                 expected,
                 link(fixture["beforeRoot"]),
                 ops,
                 &Map.fetch(after_blocks, &1)
               )

      verified = Enum.find(@proofs["fixtures"], &(&1["name"] == fixture["name"]))
      assert verified["beforeRoot"] == fixture["beforeRoot"]
      assert verified["afterRoot"] == fixture["afterRoot"]
      assert verified["operations"] == fixture["operations"]
      # This exact slice was replayed by @atproto/repo, not just Atoll's editor.
      assert proof == blocks(verified["proof"])

      assert {:ok, ^proof} =
               CommitProof.build(
                 expected,
                 link(fixture["beforeRoot"]),
                 ops,
                 &Map.fetch(proof, &1)
               )
    end
  end

  test "fixtures preserve pinned implementation provenance" do
    assert @reference["reference"] == "@atproto/repo@0.8.10"
    assert @proofs["reference"] == @reference["reference"]
    assert @proofs["implementationSha256"] == @reference["implementationSha256"]
    assert byte_size(@reference["implementationSha256"]) == 64
    assert length(@proofs["fixtures"]) == length(@reference["fixtures"])
  end

  defp cid!(value) do
    {:ok, cid} = CID.from_base32(value)
    cid
  end

  defp link(nil), do: nil
  defp link(cid), do: %CBOR.Link{cid: cid!(cid)}
  defp blocks(map), do: Map.new(map, fn {cid, bytes} -> {cid!(cid), Base.decode64!(bytes)} end)
end
