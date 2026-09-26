defmodule Atoll.Lexicon.RecordTest do
  use ExUnit.Case, async: true
  alias Atoll.Lexicon.Schema

  test "all four built-in record schemas validate, including external strong references" do
    ref = %{
      "uri" => "at://did:plc:test/app.bsky.feed.post/one",
      "cid" => Atoll.CID.create("record", :dag_cbor) |> Atoll.CID.to_base32()
    }

    for collection <- [
          "app.bsky.graph.follow",
          "app.bsky.graph.block",
          "app.bsky.feed.like",
          "app.bsky.feed.repost"
        ] do
      subject = if String.contains?(collection, ".graph."), do: "did:plc:other", else: ref

      value = %{
        "$type" => collection,
        "subject" => subject,
        "createdAt" => "2026-09-26T12:00:00Z"
      }

      assert {:ok, "valid"} = Schema.record(collection, nil, value, true)
      assert {:ok, "valid"} = Schema.record(collection, nil, value, :optimistic)

      assert {:error, :invalid_record_schema} =
               Schema.record(collection, "not-a-tid", value, true)

      assert {:error, :invalid_record_schema} =
               Schema.record(collection, nil, Map.delete(value, "subject"), true)

      assert {:error, :invalid_record_schema} =
               Schema.record(collection, nil, Map.put(value, "createdAt", "bad"), true)
    end

    like = %{
      "$type" => "app.bsky.feed.like",
      "subject" => ref,
      "createdAt" => "2026-09-26T12:00:00Z"
    }

    assert {:error, :invalid_record_schema} =
             Schema.record(
               "app.bsky.feed.like",
               nil,
               Map.put(like, "via", Map.delete(ref, "cid")),
               true
             )
  end

  test "skip and optimistic unknown modes do not claim validation" do
    assert {:ok, "unknown"} = Schema.record("app.bsky.graph.follow", "one", %{}, false)
    assert {:ok, "unknown"} = Schema.record("com.example.record", "one", %{}, :optimistic)

    assert {:error, :validation_unavailable} =
             Schema.record("com.example.record", "one", %{}, true)
  end
end
