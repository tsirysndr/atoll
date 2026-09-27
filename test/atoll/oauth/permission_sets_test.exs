defmodule Atoll.OAuth.PermissionSetsTest do
  use Atoll.DataCase, async: false
  alias Atoll.OAuth.{Permissions, PermissionSet, PermissionSets, PermissionSetCache}
  @nsid "app.example.feed.authBasic"
  @scope "include:" <> @nsid
  @now 1_800_000_000

  test "include syntax requires a scalar NSID and optional concrete DID service audience" do
    assert {:ok, %{nsid: @nsid, audience: nil}} = Permissions.include(@scope)

    assert {:ok, %{nsid: @nsid, audience: "did:web:api.example.com#app"}} =
             Permissions.include("include?nsid=" <> @nsid <> "&aud=did:web:api.example.com%23app")

    for invalid <- [
          "include:*",
          @scope <> "#main",
          @scope <> "?aud=*",
          @scope <> "?aud=did:web:api.example.com",
          @scope <> "?nsid=" <> @nsid,
          @scope <> "?aud=did:web:a.com%23a&aud=did:web:b.com%23b",
          @scope <> "?extra=x"
        ] do
      assert {:error, :invalid_scope} = Permissions.include(invalid)
    end

    # Until admission snapshots and token enforcement are integrated, this parser
    # must not accidentally let include requests pass the existing PAR allowlist.
    refute Permissions.supported?(@scope)
  end

  test "only understood declarations wholly inside the set namespace can grant access" do
    good = repo(["app.example.feed.post", "app.example.feed.deep.like"])

    declarations = [
      good,
      repo(["app.example.actor.profile"]),
      repo(["app.example.feed.post", "app.example.other"]),
      repo(["app.example.feeds.post"]),
      repo(["*"]),
      repo(["app.example.feed.*"]),
      Map.put(good, "futureRestriction", true),
      Map.put(good, "action", ["read"]),
      Map.put(good, "action", ["create", "create"]),
      Map.put(good, "collection", []),
      %{"type" => "permission", "resource" => "identity", "attr" => "*"},
      %{"type" => "permission", "resource" => "account", "attr" => "email", "action" => "manage"},
      %{"type" => "permission", "resource" => "blob", "accept" => ["*/*"]},
      %{"type" => "permission", "resource" => "include", "nsid" => @nsid},
      nil,
      "unknown"
    ]

    assert {:ok, scopes} = expand(document(declarations))
    scope = "atproto " <> Enum.join(scopes, " ")
    assert length(scopes) == 2
    assert Permissions.allows_repo?(scope, "app.example.feed.post", "create")
    assert Permissions.allows_repo?(scope, "app.example.feed.deep.like", "delete")
    refute Permissions.allows_repo?(scope, "app.example.actor.profile", "create")
    refute Permissions.allows_account?(scope, "email", "manage")
  end

  test "RPC audiences inherit only when explicit and never accept fixed service references in the set" do
    inherited = %{
      "type" => "permission",
      "resource" => "rpc",
      "lxm" => ["app.example.feed.getPosts"],
      "inheritAud" => true
    }

    wildcard =
      inherited
      |> Map.delete("inheritAud")
      |> Map.put("aud", "*")
      |> Map.put("lxm", ["app.example.feed.getPublic"])

    doc =
      document([
        inherited,
        wildcard,
        Map.put(inherited, "aud", "*"),
        Map.put(wildcard, "aud", "did:web:untrusted.example.com#app"),
        Map.put(inherited, "lxm", ["*"]),
        Map.put(inherited, "futureRestriction", true)
      ])

    assert {:ok, scopes} = expand(doc, "did:web:api.example.com#app")
    scope = "atproto " <> Enum.join(scopes, " ")
    assert length(scopes) == 2

    assert Permissions.allows_rpc?(
             scope,
             "did:web:api.example.com#app",
             "app.example.feed.getPosts"
           )

    refute Permissions.allows_rpc?(
             scope,
             "did:web:other.example.com#app",
             "app.example.feed.getPosts"
           )

    assert Permissions.allows_rpc?(
             scope,
             "did:web:other.example.com#app",
             "app.example.feed.getPublic"
           )

    assert {:ok, [only_public]} = expand(doc)

    assert Permissions.allows_rpc?(
             only_public,
             "did:web:api.example.com#app",
             "app.example.feed.getPublic"
           )
  end

  test "document and presentation metadata are bounded and validated" do
    doc = document([])
    assert {:ok, _} = PermissionSet.validate(doc, @nsid)

    for changed <- [
          put_in(doc, ["defs", "main", "permissions"], List.duplicate(%{}, 257)),
          put_in(doc, ["defs", "main", "permissions"], %{}),
          put_in(doc, ["defs", "main", "title"], String.duplicate("x", 257)),
          put_in(doc, ["defs", "main", "title:lang"], %{"not_a_language" => "Title"}),
          put_in(doc, ["defs", "main", "detail:lang"], %{"fr" => 123}),
          put_in(doc, ["defs", "main", "unknown"], true),
          put_in(doc, ["defs", "other"], %{"type" => "permission-set", "permissions" => []}),
          Map.put(doc, "description", String.duplicate("x", 262_145)),
          Map.put(doc, "id", "app.other.auth")
        ] do
      assert {:error, :invalid_permission_set} = PermissionSet.validate(changed, @nsid)
    end

    assert {:ok, _} =
             PermissionSet.validate(
               put_in(doc, ["defs", "main", "title:lang"], %{"fr" => "Accès", "zh-Hant" => "權限"}),
               @nsid
             )
  end

  test "a cache hit avoids resolution, stale failures back off without renewing expiration" do
    fetch = fn nsid, _ ->
      refute Repo.in_transaction?()
      send(self(), :fetched)

      {:ok,
       %{nsid: nsid, document: document([repo(["app.example.feed.post"])]), cid: "verified-cid"}}
    end

    assert {:ok, first} = PermissionSets.resolve(@scope, now: @now, fetch: fetch)
    assert_receive :fetched

    assert {:ok, ^first} =
             PermissionSets.resolve(@scope,
               now: @now + 86_399,
               fetch: fn _, _ -> flunk("fresh cache") end
             )

    unavailable = fn _, _ ->
      send(self(), :failed)
      {:error, :resolution_failed}
    end

    assert {:ok, ^first} = PermissionSets.resolve(@scope, now: @now + 86_400, fetch: unavailable)
    assert_receive :failed

    assert {:ok, ^first} =
             PermissionSets.resolve(@scope,
               now: @now + 86_401,
               fetch: fn _, _ -> flunk("retry backoff") end
             )

    assert {:error, :permission_set_unavailable} =
             PermissionSets.resolve(@scope, now: @now + 90 * 86_400, fetch: unavailable)

    assert {:ok, ^first} =
             PermissionSets.resolve(@scope,
               now: @now + 90 * 86_400,
               existing_session: true,
               fetch: unavailable
             )

    assert Repo.get!(PermissionSetCache, @nsid).fetched_at == @now
  end

  test "a refreshed document changes future expansions while previous snapshots remain fixed" do
    fetch = fn nsid, _ ->
      {:ok, %{nsid: nsid, document: document([repo(["app.example.feed.post"])])}}
    end

    assert {:ok, old} = PermissionSets.resolve(@scope, now: @now, fetch: fetch)

    next = fn nsid, _ ->
      {:ok, %{nsid: nsid, document: document([repo(["app.example.feed.like"])])}}
    end

    assert {:ok, fresh} = PermissionSets.resolve(@scope, now: @now + 86_400, fetch: next)
    assert fresh.document != old.document
    assert Permissions.allows_repo?(Enum.join(old.scopes, " "), "app.example.feed.post", "create")
    refute Permissions.allows_repo?(Enum.join(old.scopes, " "), "app.example.feed.like", "create")
    assert {:ok, ^fresh} = PermissionSets.resolve(@scope, now: @now + 86_401, fetch: next)
  end

  test "unknown sets fail closed and transactions cannot initiate network resolution" do
    assert {:error, :permission_set_unavailable} =
             PermissionSets.resolve(@scope, fetch: fn _, _ -> {:error, :invalid_record_proof} end)

    assert {:error, :permission_set_unavailable} =
             PermissionSets.resolve(@scope,
               fetch: fn nsid, _ -> {:ok, %{nsid: nsid, document: %{}}} end
             )

    assert Repo.aggregate(PermissionSetCache, :count) == 0

    assert {:ok, {:error, :permission_set_inside_transaction}} =
             Repo.transaction(fn ->
               PermissionSets.resolve(@scope,
                 fetch: fn _, _ -> flunk("network under transaction") end
               )
             end)
  end

  test "cache cardinality is bounded and expired entries can be reclaimed" do
    rows =
      for n <- 1..1000,
          do: %{
            nsid: "app.example.set#{n}",
            document: document([]),
            provenance: %{},
            fetched_at: @now,
            retry_at: @now
          }

    Repo.insert_all(PermissionSetCache, rows)
    fetch = fn nsid, _ -> {:ok, %{nsid: nsid, document: document([])}} end

    assert {:error, :permission_set_cache_full} =
             PermissionSets.resolve(@scope, now: @now, fetch: fetch)

    assert Repo.aggregate(PermissionSetCache, :count) == 1000
    assert {:ok, _} = PermissionSets.resolve(@scope, now: @now + 90 * 86_400, fetch: fetch)
    assert Repo.aggregate(PermissionSetCache, :count) == 1
  end

  test "cache supports valid NSIDs longer than a default varchar column" do
    nsid =
      Enum.join(
        [
          "com",
          String.duplicate("a", 63),
          String.duplicate("b", 63),
          String.duplicate("c", 63),
          String.duplicate("d", 63)
        ],
        "."
      )

    assert byte_size(nsid) > 255
    fetch = fn ^nsid, _ -> {:ok, %{nsid: nsid, document: Map.put(document([]), "id", nsid)}} end
    assert {:ok, result} = PermissionSets.resolve("include:" <> nsid, now: @now, fetch: fetch)
    assert result.nsid == nsid
  end

  test "a concurrent successful refresh wins over an older in-flight fetch" do
    fetch = fn nsid, _ -> {:ok, %{nsid: nsid, document: document([])}} end
    assert {:ok, _} = PermissionSets.resolve(@scope, now: @now, fetch: fetch)
    newer = document([repo(["app.example.feed.latest"])])

    delayed = fn nsid, _ ->
      Repo.update_all(PermissionSetCache,
        set: [document: newer, fetched_at: @now + 86_401, retry_at: @now + 86_401]
      )

      {:ok, %{nsid: nsid, document: document([repo(["app.example.feed.older"])])}}
    end

    assert {:ok, result} = PermissionSets.resolve(@scope, now: @now + 86_400, fetch: delayed)
    assert result.document == newer
    assert Repo.get!(PermissionSetCache, @nsid).document == newer
  end

  test "network resolution caches only namespace-authenticated signed repository records" do
    doc = document([repo(["app.example.feed.post"])])
    options = resolution_options(doc)
    assert {:ok, result} = PermissionSets.resolve(@scope, options)
    assert result.document == doc
    assert result.provenance["did"] == "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
    assert {:ok, _} = Atoll.CID.from_base32(result.provenance["commit"])
    assert Atoll.TID.valid?(result.provenance["rev"])

    assert {:ok, ^result} =
             PermissionSets.resolve(@scope, fetch: fn _, _ -> flunk("verified cache hit") end)
  end

  test "a substituted permission set or invalid signature cannot populate or replace the cache" do
    doc = document([repo(["app.example.feed.post"])])

    for tamper <- [:document, :signature] do
      assert {:error, :permission_set_unavailable} =
               PermissionSets.resolve(@scope, resolution_options(doc, tamper))

      assert Repo.aggregate(PermissionSetCache, :count) == 0
    end

    assert {:ok, original} = PermissionSets.resolve(@scope, resolution_options(doc))
    malicious = document([repo(["app.example.feed.deleteEverything"])])

    opts =
      Keyword.put(resolution_options(malicious, :signature), :now, original.fetched_at + 86_400)

    assert {:ok, ^original} = PermissionSets.resolve(@scope, opts)
  end

  defp resolution_options(doc, tamper \\ nil) do
    did = "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
    key = Atoll.SigningKey.generate()
    {:ok, multikey} = Atoll.Multikey.encode(key.curve, key.public)

    identity = %{
      "id" => did,
      "verificationMethod" => [
        %{
          "id" => "#atproto",
          "controller" => did,
          "type" => "Multikey",
          "publicKeyMultibase" => multikey
        }
      ],
      "service" => [
        %{
          "id" => "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => "https://pds.example.com"
        }
      ]
    }

    bytes = Atoll.CBOR.encode!(doc)
    cid = Atoll.CID.create(bytes, :dag_cbor)

    record = %{
      "uri" => "at://" <> did <> "/com.atproto.lexicon.schema/" <> @nsid,
      "cid" => Atoll.CID.to_base32(cid),
      "value" => doc
    }

    {:ok, tree} = Atoll.MST.new(%{("com.atproto.lexicon.schema/" <> @nsid) => cid})
    {:ok, rev} = Atoll.TID.next()
    signing_key = if tamper == :signature, do: Atoll.SigningKey.generate(), else: key
    {:ok, commit} = Atoll.Commit.create(did, tree.root, rev, signing_key)

    {:ok, archive} =
      Atoll.CAR.encode(
        [commit.cid],
        tree.blocks |> Map.put(cid, bytes) |> Map.put(commit.cid, commit.bytes)
      )

    [
      txt_lookup: fn "_lexicon.feed.example.app" -> [["did=" <> did]] end,
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      request:
        Req.new(
          plug: fn conn ->
            refute Repo.in_transaction?()
            assert Plug.Conn.get_req_header(conn, "authorization") == []

            case conn.request_path do
              "/" <> ^did ->
                Req.Test.json(conn, identity)

              "/xrpc/com.atproto.repo.getRecord" ->
                record =
                  if tamper == :document,
                    do: put_in(record, ["value", "defs", "main", "title"], "Tampered"),
                    else: record

                Req.Test.json(conn, record)

              "/xrpc/com.atproto.sync.getRecord" ->
                Plug.Conn.send_resp(conn, 200, archive)
            end
          end
        )
    ]
  end

  defp expand(doc, audience \\ nil),
    do: PermissionSet.expand(doc, %{nsid: @nsid, audience: audience})

  defp repo(collections),
    do: %{"type" => "permission", "resource" => "repo", "collection" => collections}

  defp document(permissions),
    do: %{
      "$type" => "com.atproto.lexicon.schema",
      "lexicon" => 1,
      "id" => @nsid,
      "defs" => %{
        "main" => %{
          "type" => "permission-set",
          "title" => "Feed access",
          "permissions" => permissions
        }
      }
    }
end
