defmodule Atoll.Lexicon.QueryTest do
  use ExUnit.Case, async: true
  alias Atoll.Lexicon.Query

  test "every routed GET method has a vendored schema" do
    methods = for %{verb: :get, path: "/xrpc/" <> nsid} <- AtollWeb.Router.__routes__(), do: nsid
    assert Enum.sort(["com.atproto.sync.subscribeRepos" | methods]) == Enum.sort(Query.methods())
  end

  test "required fields and identifier formats are enforced" do
    base = "repo=did:plc:test&collection=app.bsky.feed.post&rkey=one"
    assert {:ok, _} = Query.decode("com.atproto.repo.getRecord", base)

    for suffix <- ["", "&collection=bad", "&collection=app.bsky.feed.post&rkey=.."] do
      assert {:error, :invalid_request} =
               Query.decode("com.atproto.repo.getRecord", "repo=did:plc:test" <> suffix)
    end

    assert {:error, _} = Query.decode("com.atproto.sync.getRepo", "did=bad")
    assert {:error, _} = Query.decode("com.atproto.sync.getRepo", "did=did:plc:test&since=bad")
  end

  test "record subject queries validate at-uri syntax" do
    method = "com.atproto.admin.getSubjectStatus"
    uri = "at://did:web:example.com/com.example.record/one"
    assert {:ok, %{"uri" => ^uri}} = Query.decode(method, URI.encode_query(%{"uri" => uri}))

    for invalid <- [
          "https://example.com",
          "at://bad",
          uri <> "/extra",
          "at://did:web:example.com/com.example.record/.."
        ] do
      assert {:error, :invalid_request} =
               Query.decode(method, URI.encode_query(%{"uri" => invalid}))
    end
  end

  test "integers and booleans are validated while preserving controller input strings" do
    assert {:ok, %{"limit" => "1000"}} = Query.decode("com.atproto.sync.listRepos", "limit=1000")

    for value <- ["0", "1001", "1.0", "1e2", "%2B1", "9007199254740992"] do
      assert {:error, _} = Query.decode("com.atproto.sync.listRepos", "limit=" <> value)
    end

    for value <- ["true", "false"] do
      assert {:ok, %{"includeUsed" => ^value}} =
               Query.decode("com.atproto.server.getAccountInviteCodes", "includeUsed=" <> value)
    end

    for value <- ["1", "TRUE", "", "null"] do
      assert {:error, _} =
               Query.decode("com.atproto.server.getAccountInviteCodes", "includeUsed=" <> value)
    end
  end

  test "array values retain order, including the existing bracket alias" do
    a = Atoll.CID.create("a", :dag_cbor) |> Atoll.CID.to_base32()
    b = Atoll.CID.create("b", :dag_cbor) |> Atoll.CID.to_base32()

    assert {:ok, %{"cids" => [^a, ^b]}} =
             Query.decode(
               "com.atproto.sync.getBlocks",
               "did=did:plc:test&cids=#{a}&cids%5B%5D=#{b}"
             )

    assert {:error, _} = Query.decode("com.atproto.sync.getBlocks", "did=did:plc:test&cids=bad")
  end

  test "duplicate scalars, malformed encodings, and nested form keys fail" do
    for query <- [
          "limit=1&limit=2",
          "limit=1&%6cimit=2",
          "limit[]=1",
          "a[b]=1",
          "a=%FF",
          "%FF=a",
          "a=%",
          "a=%GG"
        ] do
      assert {:error, _} = Query.decode("com.atproto.sync.listRepos", query)
    end
  end

  test "parsing is bounded and knownValues remains an open vocabulary" do
    assert {:error, _} =
             Query.decode("com.atproto.sync.listRepos", "a=" <> String.duplicate("a", 32_767))

    pairs = Enum.map_join(1..257, "&", &"key#{&1}=v")
    assert {:error, _} = Query.decode("com.atproto.sync.listRepos", pairs)

    assert {:ok, %{"sort" => "future"}} =
             Query.decode("com.atproto.admin.getInviteCodes", "sort=future")

    assert {:ok, %{"extension" => "value"}} =
             Query.decode("com.atproto.server.describeServer", "extension=value")
  end
end
