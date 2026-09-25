defmodule Atoll.StorageTest do
  use Atoll.DataCase, async: true

  alias Atoll.{CID, Storage}
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
end
