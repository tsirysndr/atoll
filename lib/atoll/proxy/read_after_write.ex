defmodule Atoll.Proxy.ReadAfterWrite do
  @moduledoc """
  Splices local writes the AppView has not indexed yet into proxied responses.

  Applies only to the reference implementation's munged read methods, only for
  the authenticated repository owner, and only when the AppView reports an
  older `atproto-repo-rev` than recent local commits. Any parsing or munging
  failure returns the upstream response unchanged; a successful munge reports
  its staleness through `atproto-upstream-lag`.
  """
  alias Atoll.Proxy.{LocalRecords, LocalViewer}

  @thread "app.bsky.feed.getPostThread"
  @munged [
    "app.bsky.actor.getProfile",
    "app.bsky.actor.getProfiles",
    "app.bsky.feed.getActorLikes",
    "app.bsky.feed.getAuthorFeed",
    "app.bsky.feed.getTimeline",
    @thread
  ]

  def munge(nsid, response, did, query) when nsid in @munged and is_binary(did) do
    Atoll.Repo.with_primary(fn -> munge_current(nsid, response, did, query) end)
  end

  def munge(_nsid, response, _did, _query), do: response

  defp munge_current(nsid, response, did, query) do
    case {response.status, rev(response)} do
      {200, rev} when is_binary(rev) ->
        local = LocalRecords.since(did, rev)

        with false <- local.posts == [] and is_nil(local.profile),
             true <- json?(response),
             {:ok, body} <- Jason.decode(response.body),
             {:ok, munged} <- apply_munge(nsid, body, local, did) do
          finish(response, munged, local)
        else
          _ -> response
        end

      {400, rev} when is_binary(rev) and nsid == @thread ->
        recover_thread(response, did, rev, query)

      _ ->
        response
    end
  rescue
    _ -> response
  end

  defp apply_munge("app.bsky.actor.getProfile", body, %{profile: profile}, did) do
    if profile && body["did"] == did,
      do: {:ok, LocalViewer.update_profile_detailed(body, profile.record, did)},
      else: :skip
  end

  defp apply_munge("app.bsky.actor.getProfiles", body, %{profile: profile}, did) do
    with true <- not is_nil(profile),
         profiles when is_list(profiles) <- body["profiles"] do
      profiles =
        Enum.map(profiles, fn view ->
          if view["did"] == did,
            do: LocalViewer.update_profile_detailed(view, profile.record, did),
            else: view
        end)

      {:ok, Map.put(body, "profiles", profiles)}
    else
      _ -> :skip
    end
  end

  defp apply_munge("app.bsky.feed.getTimeline", body, local, did) do
    with feed when is_list(feed) <- body["feed"] do
      author = LocalViewer.profile_basic(did)

      {:ok,
       Map.put(body, "feed", LocalViewer.insert_posts_into_feed(feed, local.posts, author, did))}
    else
      _ -> :skip
    end
  end

  defp apply_munge("app.bsky.feed.getAuthorFeed", body, local, did) do
    with feed when is_list(feed) <- body["feed"],
         true <- users_feed?(feed, did) do
      feed = update_authored_posts(feed, local.profile, did)
      author = LocalViewer.profile_basic(did)

      {:ok,
       Map.put(body, "feed", LocalViewer.insert_posts_into_feed(feed, local.posts, author, did))}
    else
      _ -> :skip
    end
  end

  defp apply_munge("app.bsky.feed.getActorLikes", body, local, did) do
    with feed when is_list(feed) <- body["feed"],
         true <- not is_nil(local.profile) do
      {:ok, Map.put(body, "feed", update_authored_posts(feed, local.profile, did))}
    else
      _ -> :skip
    end
  end

  defp apply_munge(@thread, body, local, did) do
    case body["thread"] do
      %{"$type" => "app.bsky.feed.defs#threadViewPost"} = thread ->
        {:ok, Map.put(body, "thread", add_posts_to_thread(thread, local.posts, did))}

      _ ->
        :skip
    end
  end

  defp update_authored_posts(feed, nil, _did), do: feed

  defp update_authored_posts(feed, profile, did) do
    Enum.map(feed, fn
      %{"post" => %{"author" => %{"did" => ^did} = author} = post} = item ->
        author = LocalViewer.update_profile_basic(author, profile.record, did)
        Map.put(item, "post", Map.put(post, "author", author))

      item ->
        item
    end)
  end

  defp users_feed?([first | _], did) do
    case first do
      %{"reason" => %{"$type" => "app.bsky.feed.defs#reasonRepost", "by" => %{"did" => by}}} ->
        by == did

      %{"reason" => reason} when not is_nil(reason) ->
        false

      %{"post" => post} ->
        get_in(post, ["author", "did"]) == did

      _ ->
        false
    end
  end

  defp users_feed?(_, _), do: false

  defp add_posts_to_thread(thread, posts, did) do
    root = thread["post"]["uri"]
    thread_root = get_in(thread, ["post", "record", "reply", "root", "uri"]) || root

    posts
    |> Enum.filter(fn descript ->
      case get_in(descript.record, ["reply", "root", "uri"]) do
        uri when is_binary(uri) -> uri == root or uri == thread_root
        _ -> false
      end
    end)
    |> Enum.reduce(thread, &insert_into_replies(&2, &1, did))
  end

  defp insert_into_replies(view, descript, did) do
    if get_in(descript.record, ["reply", "parent", "uri"]) == view["post"]["uri"] do
      reply = thread_post_view(descript, did)
      Map.put(view, "replies", [reply | view["replies"] || []])
    else
      case view["replies"] do
        replies when is_list(replies) ->
          replies =
            Enum.map(replies, fn
              %{"$type" => "app.bsky.feed.defs#threadViewPost"} = reply ->
                insert_into_replies(reply, descript, did)

              reply ->
                reply
            end)

          Map.put(view, "replies", replies)

        _ ->
          view
      end
    end
  end

  defp thread_post_view(descript, did) do
    %{
      "$type" => "app.bsky.feed.defs#threadViewPost",
      "post" => LocalViewer.post_view(descript, LocalViewer.profile_basic(did), did)
    }
  end

  # A thread the AppView has not indexed at all can still be served from the
  # owner's local writes; the not-yet-indexed parent chain is left out.
  defp recover_thread(response, did, rev, query) do
    with true <- json?(response),
         {:ok, %{"error" => "NotFound"}} <- Jason.decode(response.body),
         %{"uri" => uri} <- URI.decode_query(query || ""),
         {:ok, authority, path} <- parse_at_uri(uri),
         ^did <- resolve_authority(authority),
         local = LocalRecords.since(did, rev),
         %{} = found <- Enum.find(local.posts, &(&1.path == path)) do
      thread =
        add_posts_to_thread(
          thread_post_view(found, did),
          Enum.reject(local.posts, &(&1.path == path)),
          did
        )

      finish(%{response | status: 200}, %{"thread" => thread}, local)
    else
      _ -> response
    end
  end

  defp parse_at_uri(uri) when is_binary(uri) do
    case String.split(uri, "/") do
      ["at:", "", authority, collection, rkey] -> {:ok, authority, collection <> "/" <> rkey}
      _ -> :error
    end
  end

  defp parse_at_uri(_), do: :error

  defp resolve_authority("did:" <> _ = did), do: did

  defp resolve_authority(handle) do
    case Atoll.Repo.get_by(Atoll.Accounts.Profile, handle: handle) do
      %{did: did} -> did
      _ -> nil
    end
  end

  defp finish(response, body, local) do
    headers = Map.put(response.headers, "atproto-upstream-lag", [lag(local)])
    %{response | body: Jason.encode!(body), headers: headers}
  end

  defp lag(local) do
    [local.profile | local.posts]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.indexed_at)
    |> Enum.min(fn -> nil end)
    |> case do
      nil ->
        "0"

      oldest ->
        {:ok, time, _} = DateTime.from_iso8601(oldest)
        max(DateTime.diff(DateTime.utc_now(), time, :millisecond), 0) |> Integer.to_string()
    end
  end

  defp rev(response) do
    case response.headers["atproto-repo-rev"] do
      [rev | _] when is_binary(rev) -> rev
      _ -> nil
    end
  end

  defp json?(response) do
    case response.headers["content-type"] do
      [type | _] -> String.starts_with?(String.downcase(type), "application/json")
      _ -> false
    end
  end
end
