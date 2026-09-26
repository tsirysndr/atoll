defmodule Atoll.Lexicon.PostProfileTest do
  use ExUnit.Case, async: true
  alias Atoll.Lexicon.Schema

  @post %{
    "$type" => "app.bsky.feed.post",
    "text" => "hello",
    "createdAt" => "2026-09-26T12:00:00Z"
  }
  @profile %{"$type" => "app.bsky.actor.profile", "displayName" => "Alice"}

  test "posts enforce grapheme and byte limits independently" do
    assert :ok = post(Map.put(@post, "text", String.duplicate("e\u0301", 300)))
    assert :error = post(Map.put(@post, "text", String.duplicate("a", 301)))

    assert :error =
             post(
               Map.put(
                 @post,
                 "text",
                 String.duplicate("a" <> String.duplicate("\u0301", 20), 100)
               )
             )

    assert :error = post(Map.delete(@post, "createdAt"))
    assert :error = post(Map.put(@post, "langs", ["en", "fr", "ja", "mg"]))
    assert :error = post(Map.put(@post, "tags", List.duplicate("tag", 9)))
  end

  test "nested image constraints and open union variants" do
    image = %{
      "alt" => "An image",
      "image" => blob("image/png", 2_000_000),
      "aspectRatio" => %{"width" => 1, "height" => 1}
    }

    embed = %{"$type" => "app.bsky.embed.images", "images" => [image]}
    assert :ok = post(Map.put(@post, "embed", embed))

    for replacement <- [blob("text/plain", 1), blob("image/png", 2_000_001)] do
      assert :error =
               post(
                 Map.put(@post, "embed", %{
                   embed
                   | "images" => [%{image | "image" => replacement}]
                 })
               )
    end

    assert :error = post(Map.put(@post, "embed", %{embed | "images" => List.duplicate(image, 5)}))

    assert :error =
             post(
               Map.put(@post, "embed", %{
                 embed
                 | "images" => [Map.put(image, "aspectRatio", %{"width" => 0, "height" => 1})]
               })
             )

    assert :ok =
             post(
               Map.put(@post, "embed", %{
                 "$type" => "com.example.futureEmbed",
                 "extension" => true
               })
             )

    assert :error = post(Map.put(@post, "embed", %{"$type" => "bad"}))
  end

  test "facets, replies, labels, and video captions validate referenced definitions" do
    facet = %{
      "index" => %{"byteStart" => 0, "byteEnd" => 5},
      "features" => [
        %{"$type" => "app.bsky.richtext.facet#link", "uri" => "https://example.com/"}
      ]
    }

    assert :ok = post(Map.put(@post, "facets", [facet]))

    assert :error =
             post(
               Map.put(@post, "facets", [
                 Map.put(facet, "index", %{"byteStart" => -1, "byteEnd" => 5})
               ])
             )

    assert :error = post(Map.put(@post, "reply", %{"root" => %{}}))

    assert :ok =
             post(
               Map.put(@post, "labels", %{
                 "$type" => "com.atproto.label.defs#selfLabels",
                 "values" => [%{"val" => "nudity"}]
               })
             )

    video = %{
      "$type" => "app.bsky.embed.video",
      "video" => blob("video/mp4", 100),
      "captions" => [%{"lang" => "en", "file" => blob("text/vtt", 20_000)}]
    }

    assert :ok = post(Map.put(@post, "embed", video))

    assert :error =
             post(
               Map.put(
                 @post,
                 "embed",
                 Map.put(video, "captions", [%{"lang" => "en_US", "file" => blob("text/vtt", 1)}])
               )
             )
  end

  test "profiles require the self key and enforce avatar and text constraints" do
    assert {:ok, "valid"} = Schema.record("app.bsky.actor.profile", "self", @profile, true)
    assert {:error, _} = Schema.record("app.bsky.actor.profile", nil, @profile, true)
    assert {:error, _} = Schema.record("app.bsky.actor.profile", "other", @profile, true)

    for fields <- [
          %{"displayName" => String.duplicate("a", 65)},
          %{"avatar" => blob("image/gif", 1)},
          %{"avatar" => blob("image/png", 1_000_001)},
          %{"website" => "relative/path"}
        ] do
      assert {:error, _} =
               Schema.record("app.bsky.actor.profile", "self", Map.merge(@profile, fields), true)
    end

    assert {:ok, "valid"} =
             Schema.record(
               "app.bsky.actor.profile",
               "self",
               Map.put(@profile, "avatar", blob("image/jpeg", 1_000_000)),
               true
             )
  end

  defp post(value) do
    case Schema.record("app.bsky.feed.post", nil, value, true) do
      {:ok, "valid"} -> :ok
      {:error, _} -> :error
    end
  end

  defp blob(mime, size),
    do: %{
      "$type" => "blob",
      "ref" => %{"$link" => Atoll.CID.create("fixture", :raw) |> Atoll.CID.to_base32()},
      "mimeType" => mime,
      "size" => size
    }
end
