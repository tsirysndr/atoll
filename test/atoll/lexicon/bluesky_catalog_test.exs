defmodule Atoll.Lexicon.BlueskyCatalogTest do
  use ExUnit.Case, async: true
  alias Atoll.Lexicon.Schema
  @time "2026-09-26T12:00:00Z"
  @uri "at://did:plc:test/app.bsky.feed.post/3k2p5f7sz2r2a"

  test "all pinned Bluesky record collections have working representative inputs" do
    cid = Atoll.CID.create("subject", :dag_cbor) |> Atoll.CID.to_base32()
    reference = %{"uri" => @uri, "cid" => cid}

    samples = [
      {"app.bsky.actor.contentVisibilityDeclaration", "self",
       %{"hideFromAlgorithmicRecommendations" => false}},
      {"app.bsky.actor.profile", "self", %{"displayName" => "Alice"}},
      {"app.bsky.actor.status", "self",
       %{"status" => "app.bsky.actor.status#live", "durationMinutes" => 5}},
      {"app.bsky.feed.generator", "my-feed",
       %{"did" => "did:web:feed.example", "displayName" => "Feed", "acceptsInteractions" => false}},
      {"app.bsky.feed.like", nil, %{"subject" => reference}},
      {"app.bsky.feed.post", nil, %{"text" => "Hello"}},
      {"app.bsky.feed.postgate", nil,
       %{"post" => @uri, "embeddingRules" => [%{"$type" => "app.bsky.feed.postgate#disableRule"}]}},
      {"app.bsky.feed.repost", nil, %{"subject" => reference}},
      {"app.bsky.feed.threadgate", nil,
       %{
         "post" => @uri,
         "allow" => [%{"$type" => "app.bsky.feed.threadgate#listRule", "list" => @uri}]
       }},
      {"app.bsky.graph.block", nil, %{"subject" => "did:plc:other"}},
      {"app.bsky.graph.follow", nil, %{"subject" => "did:plc:other"}},
      {"app.bsky.graph.list", nil,
       %{"name" => "People", "purpose" => "app.bsky.graph.defs#curatelist"}},
      {"app.bsky.graph.listblock", nil, %{"subject" => @uri}},
      {"app.bsky.graph.listitem", nil, %{"subject" => "did:plc:other", "list" => @uri}},
      {"app.bsky.graph.referencelistoptout", nil, %{"subject" => @uri}},
      {"app.bsky.graph.starterpack", nil,
       %{"name" => "Start here", "list" => @uri, "feeds" => [%{"uri" => @uri}]}},
      {"app.bsky.graph.verification", nil,
       %{"subject" => "did:plc:other", "handle" => "alice.example", "displayName" => "Alice"}},
      {"app.bsky.labeler.service", "self",
       %{
         "policies" => %{"labelValues" => ["spam"]},
         "subjectCollections" => ["app.bsky.feed.post"]
       }},
      {"app.bsky.notification.declaration", "self", %{"allowSubscriptions" => "followers"}}
    ]

    assert Enum.sort(Enum.map(samples, &elem(&1, 0))) == Enum.sort(Schema.record_collections())

    for {nsid, key, fields} <- samples do
      record = Map.merge(%{"$type" => nsid, "createdAt" => @time}, fields)
      assert {:ok, "valid"} = Schema.record(nsid, key, record, true), nsid
    end
  end

  test "new record constraints enforce types, bounds and referenced fields" do
    for {nsid, key, fields} <- [
          {"app.bsky.actor.contentVisibilityDeclaration", "self",
           %{"hideFromAlgorithmicRecommendations" => "false"}},
          {"app.bsky.actor.status", "self", %{"status" => "live", "durationMinutes" => 0}},
          {"app.bsky.feed.generator", "my-feed",
           %{"did" => "did:web:feed.example", "displayName" => String.duplicate("a", 25)}},
          {"app.bsky.graph.list", nil, %{"name" => "", "purpose" => "future-purpose"}},
          {"app.bsky.graph.starterpack", nil,
           %{"name" => "Start", "list" => @uri, "feeds" => List.duplicate(%{"uri" => @uri}, 4)}},
          {"app.bsky.feed.threadgate", nil,
           %{"post" => @uri, "allow" => [%{"$type" => "app.bsky.feed.threadgate#listRule"}]}},
          {"app.bsky.labeler.service", "self",
           %{"policies" => %{"labelValues" => ["spam"]}, "subjectCollections" => ["not-an-nsid"]}}
        ] do
      record = Map.merge(%{"$type" => nsid, "createdAt" => @time}, fields)
      assert {:error, :invalid_record_schema} = Schema.record(nsid, key, record, true), nsid
    end
  end

  test "knownValues are extensible and declaration keys remain fixed" do
    value = %{
      "$type" => "app.bsky.notification.declaration",
      "allowSubscriptions" => "future-policy"
    }

    assert {:ok, "valid"} = Schema.record(value["$type"], "self", value, true)
    assert {:error, :invalid_record_schema} = Schema.record(value["$type"], "other", value, true)
  end
end
