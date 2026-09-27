defmodule Atoll.CARStageIndexTest do
  use ExUnit.Case, async: true
  alias Atoll.CAR.StageIndex
  alias Atoll.CID

  setup do
    path = Path.join(System.tmp_dir!(), "atoll-index-test-#{System.unique_integer([:positive])}")
    {:ok, io} = File.open(path, [:read, :write, :binary, :exclusive])

    on_exit(fn ->
      File.close(io)
      File.rm(path)
    end)

    %{io: io}
  end

  test "colliding keys wrap around slots and duplicates retain their original offsets", %{io: io} do
    {:ok, index} = StageIndex.new(io, 4)

    cids =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&CID.create(Integer.to_string(&1), :raw))
      |> Stream.filter(&(slot(index, &1) == 7))
      |> Enum.take(3)

    for {cid, n} <- Enum.with_index(cids) do
      assert {:empty, position} = StageIndex.locate(index, cid)
      assert position == rem(7 + n, 8)
      assert :ok = StageIndex.put(index, position, cid, n * 100, n)
    end

    for {cid, n} <- Enum.with_index(cids),
        do: assert(StageIndex.locate(index, cid) == {:found, n * 100, n})

    assert StageIndex.locate(index, "bad") == {:error, :invalid_index_key}
  end

  test "probe limit rejects pathological clusters even with free slots elsewhere", %{io: io} do
    {:ok, index} = StageIndex.new(io, 256)
    target = CID.create("target", :raw)
    start = slot(index, target)

    for n <- 0..127 do
      assert :ok =
               StageIndex.put(
                 index,
                 rem(start + n, index.slots),
                 CID.create("other#{n}", :raw),
                 n,
                 1
               )
    end

    assert StageIndex.locate(index, target) == {:error, :index_probe_limit}
    assert :ok = :file.pwrite(io, rem(start + 127, index.slots) * 48, <<0::384>>)
    assert StageIndex.locate(index, target) == {:empty, rem(start + 127, index.slots)}
  end

  test "truncated and closed index files do not produce invented offsets", %{io: io} do
    {:ok, index} = StageIndex.new(io, 4)
    assert {:ok, 0} = :file.position(io, 0)
    assert :ok = :file.truncate(io)
    assert StageIndex.locate(index, CID.create("missing", :raw)) == {:error, :invalid_index_slot}
    assert :ok = File.close(io)
    assert StageIndex.locate(index, CID.create("missing", :raw)) == {:error, :invalid_index_slot}
    assert {:error, _} = StageIndex.new(io, 4)
  end

  defp slot(index, cid) do
    <<hash::unsigned-64, _::binary>> = :crypto.mac(:hmac, :sha256, index.key, cid)
    rem(hash, index.slots)
  end
end
