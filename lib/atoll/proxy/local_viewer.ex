defmodule Atoll.Proxy.LocalViewer do
  @moduledoc """
  Formats local records as basic Bluesky views for read-after-write munging.

  Mirrors the reference viewer without an AppView back-channel: counts are
  zero directly after creation, record embeds render as not-yet-found, and
  image URLs use the configured CDN pattern or this server's public getBlob
  route. Views built here are only spliced into responses for their author.
  """
  alias Atoll.Repo
  alias Atoll.Repositories.Record

  def profile_basic(did) do
    handle =
      case Repo.get(Atoll.Accounts.Profile, did) do
        %{handle: handle} when is_binary(handle) -> handle
        _ -> "handle.invalid"
      end

    update_profile_basic(%{"did" => did, "handle" => handle}, current_profile_record(did), did)
  end

  def current_profile_record(did) do
    with %Record{cid: cid} <- Repo.get_by(Record, did: did, path: "app.bsky.actor.profile/self"),
         {:ok, bytes} <- Atoll.Storage.get_block(cid),
         {:ok, decoded} <- Atoll.CBOR.decode(bytes),
         {:ok, record} <- Atoll.DataModel.to_json(decoded) do
      record
    else
      _ -> nil
    end
  end

  def update_profile_basic(view, record, did) do
    view
    |> Map.drop(["displayName", "avatar"])
    |> maybe_put("displayName", record && record["displayName"])
    |> maybe_put("avatar", image_url("avatar", did, blob_cid(record && record["avatar"])))
  end

  def update_profile_view(view, record, did) do
    view
    |> update_profile_basic(record, did)
    |> Map.delete("description")
    |> maybe_put("description", record && record["description"])
  end

  def update_profile_detailed(view, record, did) do
    view
    |> update_profile_view(record, did)
    |> Map.delete("banner")
    |> maybe_put("banner", image_url("banner", did, blob_cid(record && record["banner"])))
  end

  def post_view(descript, author, did) do
    %{
      "uri" => descript.uri,
      "cid" => descript.cid,
      "author" => author,
      "record" => descript.record,
      "replyCount" => 0,
      "repostCount" => 0,
      "likeCount" => 0,
      "quoteCount" => 0,
      "indexedAt" => descript.indexed_at
    }
    |> maybe_put("embed", embed_view(descript.record["embed"], did))
  end

  @doc "Splices formatted posts into a feed by indexedAt, newest first, like upstream."
  def insert_posts_into_feed(feed, posts, author, did) when is_list(feed) do
    last_time =
      case List.last(feed) do
        %{"post" => %{"indexedAt" => time}} when is_binary(time) -> time
        _ -> "1970-01-01T00:00:00.000Z"
      end

    posts
    |> Enum.filter(&(&1.indexed_at > last_time))
    |> Enum.reverse()
    |> Enum.reduce(feed, fn descript, feed ->
      item = %{"post" => post_view(descript, author, did)}

      case Enum.find_index(feed, fn
             %{"post" => %{"indexedAt" => time}} -> time < descript.indexed_at
             _ -> false
           end) do
        nil -> feed ++ [item]
        index -> List.insert_at(feed, index, item)
      end
    end)
  end

  defp embed_view(%{"$type" => "app.bsky.embed.images"} = embed, did),
    do: image_embed_view(embed, did)

  defp embed_view(%{"$type" => "app.bsky.embed.external"} = embed, did),
    do: external_embed_view(embed, did)

  defp embed_view(%{"$type" => "app.bsky.embed.record"} = embed, _did),
    do: record_embed_view(embed)

  defp embed_view(%{"$type" => "app.bsky.embed.recordWithMedia"} = embed, did) do
    media =
      case embed["media"] do
        %{"$type" => "app.bsky.embed.images"} = media -> image_embed_view(media, did)
        %{"$type" => "app.bsky.embed.external"} = media -> external_embed_view(media, did)
        _ -> nil
      end

    if media do
      %{
        "$type" => "app.bsky.embed.recordWithMedia#view",
        "record" => record_embed_view(embed["record"]),
        "media" => media
      }
    end
  end

  defp embed_view(_, _), do: nil

  defp image_embed_view(%{"images" => images}, did) when is_list(images) do
    %{
      "$type" => "app.bsky.embed.images#view",
      "images" =>
        for image <- images do
          cid = blob_cid(image["image"])

          %{
            "thumb" => image_url("feed_thumbnail", did, cid),
            "fullsize" => image_url("feed_fullsize", did, cid),
            "alt" => image["alt"] || ""
          }
          |> maybe_put("aspectRatio", image["aspectRatio"])
        end
    }
  end

  defp image_embed_view(_, _), do: nil

  defp external_embed_view(%{"external" => %{"uri" => uri} = external}, did) do
    %{
      "$type" => "app.bsky.embed.external#view",
      "external" =>
        %{
          "uri" => uri,
          "title" => external["title"] || "",
          "description" => external["description"] || ""
        }
        |> maybe_put("thumb", image_url("feed_thumbnail", did, blob_cid(external["thumb"])))
    }
  end

  defp external_embed_view(_, _), do: nil

  # Without an AppView back-channel the referenced record is not yet findable,
  # matching the reference viewer when no AppView is configured.
  defp record_embed_view(%{"record" => %{"uri" => uri}}) when is_binary(uri) do
    %{
      "$type" => "app.bsky.embed.record#view",
      "record" => %{
        "$type" => "app.bsky.embed.record#viewNotFound",
        "uri" => uri,
        "notFound" => true
      }
    }
  end

  defp record_embed_view(_), do: nil

  def image_url(_pattern, _did, nil), do: nil

  def image_url(pattern, did, cid) do
    case Application.get_env(:atoll, :image_cdn_url_pattern) do
      nil ->
        AtollWeb.Endpoint.url() <>
          "/xrpc/com.atproto.sync.getBlob?did=" <> URI.encode_www_form(did) <> "&cid=" <> cid

      format ->
        [pattern, did, cid]
        |> Enum.reduce(format, &String.replace(&2, "%s", &1, global: false))
    end
  end

  @doc false
  def cdn_pattern_from_env!(nil), do: nil

  def cdn_pattern_from_env!(value) do
    unless is_binary(value) and byte_size(value) <= 1024 and
             String.starts_with?(value, "https://") and
             length(String.split(value, "%s")) == 4,
           do:
             raise(
               ArgumentError,
               "ATOLL_IMAGE_CDN_URL_PATTERN must be an HTTPS pattern with three %s slots"
             )

    value
  end

  defp blob_cid(%{"ref" => %{"$link" => cid}}) when is_binary(cid), do: cid
  defp blob_cid(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
