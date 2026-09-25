defmodule Atoll.DataModelTest do
  use ExUnit.Case, async: true
  alias Atoll.{CBOR, CID, DataModel}
  alias Atoll.CBOR.{Bytes, Link}

  test "JSON, CBOR, and JSON round-trip with nested bytes and links" do
    cid = CID.create("blob", :raw)

    json = %{
      "$type" => "app.test.record",
      "items" => [%{"$link" => CID.to_base32(cid)}, %{"$bytes" => "AP8="}, false, nil]
    }

    assert {:ok, node} = DataModel.from_json(json)
    assert node["items"] == [%Link{cid: cid}, %Bytes{data: <<0, 255>>}, false, nil]
    assert {:ok, ^node} = CBOR.decode(CBOR.encode!(node))
    assert DataModel.to_json(node) == {:ok, json}
  end

  test "accepts padded and unpadded standard base64" do
    for text <- ["AP8=", "AP8"] do
      assert DataModel.from_json(%{"$bytes" => text}) == {:ok, %Bytes{data: <<0, 255>>}}
    end
  end

  test "rejects malformed special objects and invalid data" do
    for value <- [
          %{"$link" => "bad"},
          %{"$bytes" => "_w"},
          %{"$bytes" => 4},
          %{"$bytes" => "AA==", "extra" => 1},
          %{"$link" => "bad", "$bytes" => ""},
          %{a: 1},
          1.5,
          <<255>>,
          9_223_372_036_854_775_808
        ] do
      assert DataModel.from_json(value) == {:error, :invalid_data}
    end
  end

  test "preserves unknown reserved fields and rejects excessive nesting" do
    assert DataModel.to_json(%Link{cid: nil}) == {:error, :invalid_data}
    assert DataModel.to_json(%Bytes{data: nil}) == {:error, :invalid_data}
    value = %{"$future" => "preserved", "$type" => "app.test.record"}
    assert DataModel.from_json(value) == {:ok, value}
    deep = Enum.reduce(1..65, 0, fn _, acc -> [acc] end)
    assert DataModel.from_json(deep) == {:error, :invalid_data}
    assert DataModel.to_json(deep) == {:error, :invalid_data}
  end
end
