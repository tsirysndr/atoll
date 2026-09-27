defmodule AtollWeb.ReadAfterWriteTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{Blobs, CID, KeyVault, Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{Credentials, Profile, Sessions}
  @did "did:plc:readafterwrite"
  @service "did:web:appview.example.com"
  @aud @service <> "#bsky_appview"

  setup %{conn: conn} do
    keys = [:session_signing_key, :key_encryption_key, :proxy_options, :blob_storage]
    previous = Map.new(keys, &{&1, Application.fetch_env(:atoll, &1)})

    for key <- [:session_signing_key, :key_encryption_key],
        do: Application.put_env(:atoll, key, :crypto.strong_rand_bytes(32))

    Application.put_env(:atoll, :blob_storage, backend: :postgres)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    key = SigningKey.generate()
    {:ok, genesis} = Repositories.create(@did, key)
    {:ok, :stored} = KeyVault.store(@did, key)
    Repo.insert!(%Profile{did: @did, handle: "raw.example.com"})
    {:ok, _} = Credentials.create(@did, "read after write password")
    {:ok, pair} = Sessions.create(@did, "read after write password")

    {:ok, blob} = Blobs.stage(@did, "portrait bytes", "image/png")

    {:ok, _} =
      Repositories.apply_writes(
        @did,
        [
          {:put, "app.bsky.actor.profile/self",
           %{
             "$type" => "app.bsky.actor.profile",
             "displayName" => "Fresh Name",
             "description" => "fresh description",
             "avatar" => blob
           }}
        ],
        key
      )

    root = %{
      "$type" => "app.bsky.feed.post",
      "text" => "root post",
      "createdAt" => "2026-09-27T00:00:00.000Z",
      "embed" => %{
        "$type" => "app.bsky.embed.images",
        "images" => [%{"image" => blob, "alt" => "portrait"}]
      }
    }

    {:ok, _} = Repositories.apply_writes(@did, [{:put, "app.bsky.feed.post/root1", root}], key)
    root_uri = "at://#{@did}/app.bsky.feed.post/root1"

    root_ref = %{
      "uri" => root_uri,
      "cid" =>
        CID.to_base32(
          Repo.get_by!(Repositories.Record, did: @did, path: "app.bsky.feed.post/root1").cid
        )
    }

    reply = %{
      "$type" => "app.bsky.feed.post",
      "text" => "fresh reply",
      "createdAt" => "2026-09-27T00:00:01.000Z",
      "reply" => %{"root" => root_ref, "parent" => root_ref}
    }

    {:ok, head} =
      Repositories.apply_writes(@did, [{:put, "app.bsky.feed.post/reply1", reply}], key)

    id = rem(System.unique_integer([:positive]), 65_536)

    %{
      conn: %{conn | remote_ip: {10, 71, div(id, 256), rem(id, 256)}},
      pair: pair,
      genesis_rev: genesis.rev,
      head_rev: head.rev,
      root_uri: root_uri,
      blob_cid: blob["ref"]["$link"]
    }
  end

  defp upstream(rev, body, status \\ 200) do
    Application.put_env(:atoll, :proxy_options,
      resolver: [
        lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
        request:
          Req.new(
            plug: fn conn ->
              Req.Test.json(conn, %{
                "id" => @service,
                "service" => [
                  %{
                    "id" => "#bsky_appview",
                    "type" => "BskyAppView",
                    "serviceEndpoint" => "https://api.example.com"
                  }
                ]
              })
            end
          )
      ],
      lookup: fn "api.example.com" -> {:ok, {1, 1, 1, 1}} end,
      request:
        Req.new(
          plug: fn conn ->
            conn
            |> Plug.Conn.put_resp_header("atproto-repo-rev", rev)
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(status, Jason.encode!(body))
          end
        )
    )
  end

  defp fetch(c, path, query \\ "") do
    c.conn
    |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
    |> put_req_header("atproto-proxy", @aud)
    |> get(path <> query)
  end

  test "stale timelines gain fresh local posts with formatted embeds", c do
    upstream(c.genesis_rev, %{"feed" => [], "cursor" => "page"})
    response = fetch(c, "/xrpc/app.bsky.feed.getTimeline")
    body = json_response(response, 200)
    assert [lag] = get_resp_header(response, "atproto-upstream-lag")
    assert String.to_integer(lag) >= 0
    assert body["cursor"] == "page"
    assert [%{"post" => reply_view}, %{"post" => root_view}] = body["feed"]
    assert reply_view["record"]["text"] == "fresh reply"
    assert root_view["uri"] == c.root_uri
    assert root_view["author"]["handle"] == "raw.example.com"
    assert root_view["author"]["displayName"] == "Fresh Name"
    assert root_view["likeCount"] == 0

    assert [%{"thumb" => thumb, "fullsize" => fullsize, "alt" => "portrait"}] =
             root_view["embed"]["images"]

    assert root_view["embed"]["$type"] == "app.bsky.embed.images#view"
    assert String.contains?(thumb, "/xrpc/com.atproto.sync.getBlob?did=")
    assert String.contains?(fullsize, c.blob_cid)

    # A current AppView revision passes through untouched.
    upstream(c.head_rev, %{"feed" => [], "cursor" => "page"})
    response = fetch(c, "/xrpc/app.bsky.feed.getTimeline")
    assert json_response(response, 200)["feed"] == []
    assert get_resp_header(response, "atproto-upstream-lag") == []

    # A revision before all local history is never munged from a foreign clock.
    upstream("2222222222222", %{"feed" => []})
    assert fetch(c, "/xrpc/app.bsky.feed.getTimeline") |> json_response(200) == %{"feed" => []}
  end

  test "profiles gain local edits only for the requester", c do
    upstream(c.genesis_rev, %{
      "did" => @did,
      "handle" => "raw.example.com",
      "displayName" => "Stale Name",
      "banner" => "https://cdn.example.com/banner.jpg"
    })

    body = fetch(c, "/xrpc/app.bsky.actor.getProfile") |> json_response(200)
    assert body["displayName"] == "Fresh Name"
    assert body["description"] == "fresh description"
    assert String.contains?(body["avatar"], c.blob_cid)
    refute Map.has_key?(body, "banner")

    upstream(c.genesis_rev, %{"did" => "did:plc:someoneelse", "displayName" => "Stale Name"})
    body = fetch(c, "/xrpc/app.bsky.actor.getProfile") |> json_response(200)
    assert body["displayName"] == "Stale Name"

    upstream(c.genesis_rev, %{
      "profiles" => [
        %{"did" => @did, "displayName" => "Stale Name"},
        %{"did" => "did:plc:someoneelse", "displayName" => "Unrelated"}
      ]
    })

    body = fetch(c, "/xrpc/app.bsky.actor.getProfiles") |> json_response(200)
    assert [%{"displayName" => "Fresh Name"}, %{"displayName" => "Unrelated"}] = body["profiles"]
  end

  test "unindexed threads are recovered from local records for their author", c do
    upstream(c.genesis_rev, %{"error" => "NotFound", "message" => "Post not found"}, 400)

    body =
      fetch(c, "/xrpc/app.bsky.feed.getPostThread", "?uri=" <> URI.encode_www_form(c.root_uri))
      |> json_response(200)

    thread = body["thread"]
    assert thread["$type"] == "app.bsky.feed.defs#threadViewPost"
    assert thread["post"]["uri"] == c.root_uri
    assert [reply] = thread["replies"]
    assert reply["post"]["record"]["text"] == "fresh reply"

    # Someone else's missing thread stays an upstream error.
    other = "at://did:plc:someoneelse/app.bsky.feed.post/x"

    assert fetch(c, "/xrpc/app.bsky.feed.getPostThread", "?uri=" <> URI.encode_www_form(other))
           |> json_response(400) == %{"error" => "NotFound", "message" => "Post not found"}
  end

  test "author feeds munge only when they belong to the requester", c do
    foreign = %{
      "feed" => [
        %{
          "post" => %{
            "uri" => "at://did:plc:someoneelse/app.bsky.feed.post/a",
            "indexedAt" => "2030-01-01T00:00:00.000Z",
            "author" => %{"did" => "did:plc:someoneelse", "displayName" => "Stale Name"}
          }
        }
      ]
    }

    upstream(c.genesis_rev, foreign)
    assert fetch(c, "/xrpc/app.bsky.feed.getAuthorFeed") |> json_response(200) == foreign

    own = %{
      "feed" => [
        %{
          "post" => %{
            "uri" => c.root_uri,
            "indexedAt" => "2020-01-01T00:00:00.000Z",
            "author" => %{"did" => @did, "displayName" => "Stale Name"}
          }
        }
      ]
    }

    upstream(c.genesis_rev, own)
    body = fetch(c, "/xrpc/app.bsky.feed.getAuthorFeed") |> json_response(200)
    assert [%{"post" => first}, %{"post" => second}, %{"post" => third}] = body["feed"]
    assert first["record"]["text"] == "fresh reply"
    assert second["record"]["text"] == "root post"
    assert third["author"]["displayName"] == "Fresh Name"
  end
end
