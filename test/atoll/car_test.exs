defmodule Atoll.CARTest do
  use ExUnit.Case, async: true
  alias Atoll.{CAR, CBOR, CID, MST, Varint}
  alias Atoll.CBOR.Link

  test "encodes the CARv1 header and section framing exactly" do
    # Independently assembled CARv1 bytes: map(roots=[], version=1).
    empty = Base.decode16!("11A265726F6F7473806776657273696F6E01")
    assert CAR.encode([], %{}) == {:ok, empty}
    assert CAR.decode(empty) == {:ok, %{roots: [], blocks: %{}}}

    cid = CID.create("hello", :raw)
    assert {:ok, archive} = CAR.encode([cid], %{cid => "hello"})

    expected_header =
      <<0xA2, 0x65, "roots", 0x81, 0xD8, 0x2A, 0x58, 37, 0>> <>
        cid <> <<0x67, "version", 1>>

    assert archive == <<58>> <> expected_header <> <<41>> <> cid <> "hello"
    assert CAR.decode(archive) == {:ok, %{roots: [cid], blocks: %{cid => "hello"}}}
  end

  test "transports a complete MST and its record blocks" do
    record = CBOR.encode!(%{"$type" => "com.example.record", "text" => "hello"})
    cid = CID.create(record, :dag_cbor)
    assert {:ok, tree} = MST.new(%{"com.example.record/self" => cid})
    blocks = Map.put(tree.blocks, cid, record)
    assert {:ok, archive} = CAR.encode([tree.root], blocks)
    assert {:ok, %{roots: [root], blocks: decoded}} = CAR.decode(archive)
    assert decoded == blocks
    assert {:ok, loaded} = MST.load(root, decoded)
    assert loaded.records == tree.records
  end

  test "permits partial archives and deduplicates verified repeated sections" do
    cid = CID.create("", :raw)
    header = frame(CBOR.encode!(%{"roots" => [%Link{cid: cid}], "version" => 1}))
    assert CAR.decode(header) == {:ok, %{roots: [cid], blocks: %{}}}
    section = frame(cid)

    assert CAR.decode(header <> section <> section) ==
             {:ok, %{roots: [cid], blocks: %{cid => ""}}}

    bad = CID.create("wrong", :raw)
    assert CAR.decode(header <> frame(bad)) == {:error, :invalid_car}
  end

  test "rejects malformed headers, lengths, CIDs, and content" do
    {:ok, empty} = CAR.encode([], %{})
    cid = CID.create("hello", :raw)
    {:ok, valid} = CAR.encode([cid], %{cid => "hello"})

    for bad <- [
          nil,
          "",
          <<0>>,
          <<0x91, 0>> <> binary_part(empty, 1, 17),
          empty <> <<0>>,
          empty <> <<128>>,
          empty <> frame(<<1, 2>>),
          empty <> frame(cid <> "wrong"),
          frame(CBOR.encode!(%{"roots" => [], "version" => 2})),
          frame(CBOR.encode!(%{"roots" => ["not a link"], "version" => 1}))
        ] do
      assert CAR.decode(bad) == {:error, :invalid_car}
    end

    # All proper prefixes of a one-block CAR fail except its complete header,
    # which is itself a valid partial archive.
    for size <- 0..(byte_size(valid) - 1), size != 59 do
      assert CAR.decode(binary_part(valid, 0, size)) == {:error, :invalid_car}
    end

    assert CAR.encode(["bad"], %{}) == {:error, :invalid_car}
    assert CAR.encode([], %{cid => "wrong"}) == {:error, :invalid_car}
    assert CAR.encode([], %{cid => nil}) == {:error, :invalid_car}
  end

  test "enforces section, header, and block-count limits before reading payloads" do
    assert CAR.decode(Varint.encode(65_537)) == {:error, :car_too_large}
    {:ok, empty} = CAR.encode([], %{})
    assert CAR.decode(empty <> Varint.encode(2_097_153)) == {:error, :car_too_large}
    cid = CID.create("", :raw)
    assert CAR.decode(empty <> :binary.copy(frame(cid), 100_001)) == {:error, :car_too_large}
  end

  defp frame(bytes), do: Varint.encode(byte_size(bytes)) <> bytes
end
