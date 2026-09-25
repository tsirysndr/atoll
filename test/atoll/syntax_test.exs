defmodule Atoll.SyntaxTest do
  use ExUnit.Case, async: true
  alias Atoll.Syntax

  test "validates DID syntax independently from supported methods" do
    for value <- [
          "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
          "did:web:user.example.com",
          "did:method::::val"
        ],
        do: assert(Syntax.did?(value))

    for value <- [
          nil,
          "DID:web:example.com",
          "did:m123:v",
          "did:web:",
          "did:web:host/",
          "did:m:v\n"
        ],
        do: refute(Syntax.did?(value))
  end

  test "validates handles and NSIDs with byte limits" do
    for value <- ["8.cn", "XX.LCS.MIT.EDU", "name.t--t", "handle.invalid"],
        do: assert(Syntax.handle?(value))

    for value <- [
          "foo",
          "a.8",
          "a..com",
          "a.com.",
          "a-.com",
          "é.com",
          String.duplicate("a", 64) <> ".com"
        ],
        do: refute(Syntax.handle?(value))

    for value <- ["com.example.fooBar", "a.b.c", "cn.8.lex.stuff"],
        do: assert(Syntax.nsid?(value))

    for value <- ["com.example", "com.example.3", "com.example.foo-bar", "8.cn.foo"],
        do: refute(Syntax.nsid?(value))
  end

  test "validates record keys, normalized repository paths, and restricted AT URIs" do
    for key <- ["self", "pre:fix", "~1.2-3_"], do: assert(Syntax.record_key?(key))

    for key <- ["", ".", "..", "a/b", "x%20", String.duplicate("x", 513)],
        do: refute(Syntax.record_key?(key))

    assert Syntax.repo_path?("app.bsky.feed.post/self")
    refute Syntax.repo_path?("APP.bsky.feed.post/self")

    for uri <- ["at://example.com", "at://did:web:example.com/app.bsky.feed.post/self"],
        do: assert(Syntax.at_uri?(uri))

    for uri <- [
          "at://example.com/",
          "at://example.com/a",
          "at://example.com/app.bsky.feed.post/x?y",
          "at://EXAMPLE.com"
        ],
        do: refute(Syntax.at_uri?(uri))
  end
end
