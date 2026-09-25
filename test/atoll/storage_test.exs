defmodule Atoll.StorageTest do
  use Atoll.DataCase, async: true

  alias Atoll.{CID, Storage}
  alias Atoll.CBOR.{Bytes, Link}
  alias Atoll.Storage.Block

  test "stores and retrieves exact content bytes" do
    for {data, codec} <- [
          {<<0, 255, 128>>, :raw},
          {<<>>, :raw},
          {<<0xA0>>, :dag_cbor}
        ] do
      cid = CID.create(data, codec)

      assert Storage.put_block(cid, data) == :ok
      assert Storage.get_block(cid) == {:ok, data}
    end
  end

  test "repeated inserts keep a single block" do
    data = "hello"
    cid = CID.create(data, :raw)

    assert Storage.put_block(cid, data) == :ok
    assert Storage.put_block(cid, data) == :ok

    assert Repo.aggregate(Block, :count) == 1
    assert Storage.get_block(cid) == {:ok, data}
  end

  test "rejects mismatched content without inserting it" do
    cid = CID.create("hello", :raw)

    assert Storage.put_block(cid, "different") ==
             {:error, :content_mismatch}

    assert Repo.aggregate(Block, :count) == 0
  end

  test "rejects mismatched content even when the CID already exists" do
    cid = CID.create("hello", :raw)
    assert Storage.put_block(cid, "hello") == :ok

    assert Storage.put_block(cid, "different") ==
             {:error, :content_mismatch}

    assert Storage.get_block(cid) == {:ok, "hello"}
    assert Repo.aggregate(Block, :count) == 1
  end

  test "rejects malformed CIDs without inserting them" do
    assert Storage.put_block(<<1, 2>>, "hello") ==
             {:error, :invalid_cid}

    assert Repo.aggregate(Block, :count) == 0
  end

  test "returns not_found for a valid CID that is not stored" do
    cid = CID.create("missing", :raw)

    assert Storage.get_block(cid) == {:error, :not_found}
  end

  test "rejects malformed CIDs when fetching" do
    assert Storage.get_block(<<1, 2>>) == {:error, :invalid_cid}
  end

  test "stores and retrieves a structured node" do
    linked_cid = CID.create("hello", :raw)

    value = %{
      "text" => "hello",
      "items" => [1, true, nil],
      "bytes" => %Bytes{data: <<0, 255>>},
      "ref" => %Link{cid: linked_cid}
    }

    assert {:ok, cid} = Storage.put_node(value)
    assert Storage.get_node(cid) == {:ok, value}
  end

  test "stores the empty map under its known CID without duplicates" do
    assert {:ok, cid} = Storage.put_node(%{})

    assert CID.to_base32(cid) ==
             "bafyreigbtj4x7ip5legnfznufuopl4sg4knzc2cof6duas4b3q2fy6swua"

    assert Storage.put_node(%{}) == {:ok, cid}
    assert Storage.get_block(cid) == {:ok, <<0xA0>>}
    assert Repo.aggregate(Block, :count) == 1
  end

  test "refuses to interpret raw blocks as CBOR nodes" do
    cid = CID.create(<<0xA0>>, :raw)
    assert Storage.put_block(cid, <<0xA0>>) == :ok

    assert Storage.get_node(cid) == {:error, :unsupported_codec}
  end

  test "distinguishes missing nodes from malformed CIDs" do
    cid = CID.create(<<0xA0>>, :dag_cbor)

    assert Storage.get_node(cid) == {:error, :not_found}
    assert Storage.get_node(<<1, 2>>) == {:error, :invalid_cid}
  end

  test "rejects stored content that hashes correctly but is invalid CBOR" do
    data = <<0xFF>>
    cid = CID.create(data, :dag_cbor)
    assert Storage.put_block(cid, data) == :ok

    assert Storage.get_node(cid) == {:error, :invalid_cbor}
  end

  test "detects stored content that no longer matches its CID" do
    assert {:ok, cid} = Storage.put_node(%{})

    # Bypass the storage API to simulate corrupted database content.
    Repo.update_all(Block, set: [data: <<0x80>>])

    assert Storage.get_node(cid) == {:error, :content_mismatch}
  end

  test "rejects unsupported or excessively nested nodes without inserting" do
    too_deep = Enum.reduce(1..65, 0, fn _, value -> [value] end)

    for value <- [1.5, %{bad: true}, too_deep] do
      assert Storage.put_node(value) == {:error, :invalid_cbor}
    end

    assert Repo.aggregate(Block, :count) == 0
  end
end
