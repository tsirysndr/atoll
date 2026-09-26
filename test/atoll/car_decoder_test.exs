defmodule Atoll.CARDecoderTest do
  use ExUnit.Case, async: true
  alias Atoll.{CAR, CID, Varint}
  alias Atoll.CAR.Decoder
  defp consume(event, acc), do: {:cont, [event | acc]}

  test "decodes at every possible boundary including split varints and empty records" do
    blocks = Map.new(["", String.duplicate("x", 300)], &{CID.create(&1, :raw), &1})
    roots = [CID.create("", :raw)]
    {:ok, archive} = CAR.encode(roots, blocks)

    for split <- 0..byte_size(archive) do
      <<a::binary-size(split), b::binary>> = archive
      assert {:ok, state, acc} = Decoder.feed(Decoder.new(), a, [], &consume/2)
      assert {:ok, state, acc} = Decoder.feed(state, b, acc, &consume/2)
      assert :ok = Decoder.finish(state)
      assert [{:header, ^roots} | events] = Enum.reverse(acc)
      assert Map.new(events, fn {:block, cid, bytes} -> {cid, bytes} end) == blocks
    end

    {state, _} =
      Enum.reduce(:binary.bin_to_list(archive), {Decoder.new(), []}, fn byte, {state, acc} ->
        {:ok, state, acc} = Decoder.feed(state, <<byte>>, acc, &consume/2)
        {state, acc}
      end)

    assert :ok = Decoder.finish(state)
  end

  test "rejects truncated frames, invalid lengths, corrupted blocks and limit overruns" do
    cid = CID.create("body", :raw)
    {:ok, archive} = CAR.encode([cid], %{cid => "body"})

    for count <- [0, 1, byte_size(archive) - 1] do
      {:ok, state, _} =
        Decoder.feed(Decoder.new(), binary_part(archive, 0, count), [], &consume/2)

      assert {:error, :invalid_car} = Decoder.finish(state)
    end

    for prefix <- [<<0>>, <<128, 0>>, :binary.copy(<<255>>, 10)] do
      assert {:error, :invalid_car} = Decoder.feed(Decoder.new(), prefix, [], &consume/2)
    end

    assert {:error, :car_too_large} =
             Decoder.feed(Decoder.new(), Varint.encode(65_537), [], &consume/2)

    assert {:error, :car_too_large} =
             Decoder.feed(Decoder.new(max_bytes: 5), archive, [], &consume/2)

    corrupt = binary_part(archive, 0, byte_size(archive) - 1) <> <<0>>
    assert {:error, :invalid_car} = Decoder.feed(Decoder.new(), corrupt, [], &consume/2)
    {:ok, stream} = CAR.encode_stream([], [{cid, "body"}, {cid, "body"}])
    duplicate = stream |> Enum.to_list() |> IO.iodata_to_binary()

    assert {:error, :car_too_large} =
             Decoder.feed(Decoder.new(max_blocks: 1), duplicate, [], &consume/2)
  end

  test "consumer cancellation stops before subsequent blocks are processed" do
    {:ok, archive} = CAR.encode([], %{})

    assert {:halt, :header_seen} =
             Decoder.feed(Decoder.new(), archive <> <<255, 0>>, nil, fn {:header, []}, nil ->
               {:halt, :header_seen}
             end)
  end

  test "validates more than 64 MiB without collecting output" do
    bytes = String.duplicate("x", 1_048_576)
    cid = CID.create(bytes, :raw)

    {:ok, chunks} =
      CAR.encode_stream([cid], Stream.repeatedly(fn -> {cid, bytes} end) |> Stream.take(65))

    {state, count} =
      Enum.reduce(chunks, {Decoder.new(), 0}, fn chunk, {state, count} ->
        {:ok, state, count} = Decoder.feed(state, chunk, count, fn _, n -> {:cont, n + 1} end)
        {state, count}
      end)

    assert count == 66
    assert state.total > 64 * 1024 * 1024
    assert :ok = Decoder.finish(state)
  end
end
