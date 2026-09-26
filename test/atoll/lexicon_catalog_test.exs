defmodule Atoll.LexiconCatalogTest do
  use ExUnit.Case, async: true
  alias Atoll.Lexicon.Catalog

  defp schema(id, refs \\ []) do
    properties =
      Map.new(Enum.with_index(refs), fn {ref, i} ->
        {"field#{i}", %{"type" => "ref", "ref" => ref}}
      end)

    %{
      "$type" => "com.atproto.lexicon.schema",
      "lexicon" => 1,
      "id" => id,
      "defs" => %{"main" => %{"type" => "object", "properties" => properties}}
    }
  end

  defp fetcher(docs) do
    fn nsid, _ ->
      send(self(), {:fetch, nsid})

      case Map.fetch(docs, nsid) do
        {:ok, document} ->
          {:ok,
           %{
             nsid: nsid,
             document: document,
             did: "did:web:publisher.example.com",
             uri: "at://did:web:publisher.example.com/com.atproto.lexicon.schema/#{nsid}",
             cid: "test-cid"
           }}

        :error ->
          {:error, :lexicon_not_found}
      end
    end
  end

  test "resolves shared and cyclic dependencies once and preserves provenance" do
    a = "com.example.alpha"
    b = "org.other.beta"
    c = "net.third.gamma"
    docs = %{a => schema(a, [b, c, "#main"]), b => schema(b, [c]), c => schema(c, [a])}
    assert {:ok, result} = Catalog.resolve(a, fetch: fetcher(docs))

    for id <- [a, b, c] do
      assert_receive {:fetch, ^id}
      assert result.documents[id] == Map.delete(docs[id], "$type")
      assert result.provenance[id].did == "did:web:publisher.example.com"
    end

    refute_receive {:fetch, _}
    assert Map.has_key?(result.documents, "app.bsky.feed.post")
  end

  test "uses bundled dependencies without fetching or replacing them" do
    id = "com.example.record"
    docs = %{id => schema(id, ["app.bsky.richtext.facet"])}
    assert {:ok, result} = Catalog.resolve(id, fetch: fetcher(docs))
    assert_receive {:fetch, ^id}
    refute_receive {:fetch, _}

    assert result.documents["app.bsky.richtext.facet"] ==
             Atoll.Lexicon.Schema.builtin_documents()["app.bsky.richtext.facet"]
  end

  test "rejects missing dependencies, unresolved fragments and unsupported documents" do
    id = "com.example.record"

    assert {:error, :lexicon_not_found} =
             Catalog.resolve(id, fetch: fetcher(%{id => schema(id, ["org.other.missing"])}))

    assert {:error, :invalid_lexicon_schema} =
             Catalog.resolve(id, fetch: fetcher(%{id => schema(id, ["#absent"])}))

    invalid = put_in(schema(id), ["defs", "main", "type"], "unsupported")

    assert {:error, :invalid_lexicon_schema} =
             Catalog.resolve(id, fetch: fetcher(%{id => invalid}))
  end

  test "limits fanout before contacting excessive dependencies" do
    id = "com.example.record"
    refs = Enum.map(1..16, &"com.example.dependency#{&1}")

    assert {:error, :lexicon_catalog_too_large} =
             Catalog.resolve(id, fetch: fetcher(%{id => schema(id, refs)}))

    assert_receive {:fetch, ^id}
    refute_receive {:fetch, _}
  end

  test "limits aggregate catalog bytes and never installs a partial catalog" do
    before = Application.get_env(:atoll, :record_lexicons)
    ids = Enum.map(1..6, &"com.example.schema#{&1}")

    docs =
      Map.new(Enum.with_index(ids), fn {id, index} ->
        refs = Enum.take(Enum.drop(ids, index + 1), 1)
        {id, Map.put(schema(id, refs), "description", String.duplicate("x", 220_000))}
      end)

    assert {:error, :lexicon_catalog_too_large} = Catalog.resolve(hd(ids), fetch: fetcher(docs))
    assert Application.get_env(:atoll, :record_lexicons) == before
  end

  test "rejects a catalog when its final fetch exceeds the elapsed-time budget" do
    counter = :counters.new(1, [])

    clock = fn ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) <= 2, do: 0, else: 30_000
    end

    id = "com.example.record"

    assert {:error, :lexicon_resolution_timeout} =
             Catalog.resolve(id, fetch: fetcher(%{id => schema(id)}), clock: clock)

    assert_receive {:fetch, ^id}
  end
end
