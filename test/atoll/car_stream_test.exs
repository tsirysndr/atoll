defmodule Atoll.CARStreamTest do
  use ExUnit.Case, async: true
  alias Atoll.{CAR, CID}

  test "matches the buffered encoding for the same block order" do
    blocks = Map.new(["one", "two", "three"], &{CID.create(&1, :raw), &1})
    roots = [CID.create("one", :raw)]
    assert {:ok, expected} = CAR.encode(roots, blocks)
    assert {:ok, stream} = CAR.encode_stream(roots, Enum.sort(blocks))
    assert stream |> Enum.to_list() |> IO.iodata_to_binary() == expected
    assert {:ok, %{roots: ^roots, blocks: ^blocks}} = CAR.decode(expected)
  end

  test "reads lazily and releases an upstream resource when the consumer halts" do
    cid = CID.create("one", :raw)

    source =
      Stream.resource(
        fn -> 0 end,
        fn n ->
          send(self(), {:read, n})
          {[{cid, "one"}], n + 1}
        end,
        fn n -> send(self(), {:closed, n}) end
      )

    assert {:ok, stream} = CAR.encode_stream([cid], source)
    refute_receive {:read, _}
    assert length(Enum.take(stream, 2)) == 2
    assert_receive {:read, 0}
    assert_receive {:closed, 1}
    refute_receive {:read, _}
  end

  test "invalid blocks abort enumeration and close the upstream resource" do
    cid = CID.create("one", :raw)

    source =
      Stream.resource(
        fn -> :ready end,
        fn state ->
          {[{cid, "tampered"}], state}
        end,
        fn _ -> send(self(), :closed) end
      )

    assert {:ok, stream} = CAR.encode_stream([cid], source)
    assert_raise ArgumentError, "Invalid CAR stream block", fn -> Enum.to_list(stream) end
    assert_receive :closed

    for item <- [:bad, {"not-a-cid", "one"}, {cid, String.duplicate("x", 2_097_152)}] do
      assert {:ok, stream} = CAR.encode_stream([], [item])
      assert_raise ArgumentError, fn -> Enum.to_list(stream) end
    end

    assert {:error, :invalid_car} = CAR.encode_stream(["bad"], [])
    assert {:error, :invalid_car} = CAR.encode_stream([], :not_enumerable)
  end

  test "streams beyond the buffered archive cap without accumulating an archive" do
    data = :binary.copy(<<7>>, 1_048_576)
    cid = CID.create(data, :raw)
    blocks = Stream.repeatedly(fn -> {cid, data} end) |> Stream.take(65)
    assert {:ok, stream} = CAR.encode_stream([cid], blocks)

    {chunks, size} =
      Enum.reduce(stream, {0, 0}, fn bytes, {count, total} ->
        {count + 1, total + byte_size(bytes)}
      end)

    assert chunks == 66
    assert size > 64 * 1024 * 1024
  end
end
