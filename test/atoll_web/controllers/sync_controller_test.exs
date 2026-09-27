defmodule AtollWeb.SyncControllerTest do
  use AtollWeb.ConnCase, async: true
  alias Atoll.{CID, Repositories, SigningKey}
  @latest "/xrpc/com.atproto.sync.getLatestCommit"
  @status "/xrpc/com.atproto.sync.getRepoStatus"
  @list "/xrpc/com.atproto.sync.listRepos"

  test "latest commit and status track committed writes", %{conn: conn} do
    key = SigningKey.generate()
    did = "did:plc:example"
    {:ok, initial} = Repositories.create(did, key)

    assert conn |> get(@latest, %{did: did}) |> json_response(200) == %{
             "cid" => CID.to_base32(initial.head),
             "rev" => initial.rev
           }

    {:ok, updated} =
      Repositories.apply_writes(
        did,
        [{:put, "com.example.record/self", %{"$type" => "com.example.record"}}],
        key
      )

    assert conn |> get(@latest, %{did: did}) |> json_response(200) == %{
             "cid" => CID.to_base32(updated.head),
             "rev" => updated.rev
           }

    assert conn |> get(@status, %{did: did}) |> json_response(200) == %{
             "did" => did,
             "rev" => updated.rev,
             "active" => true
           }
  end

  test "lists repository heads with a stable exclusive cursor", %{conn: conn} do
    assert conn |> get(@list) |> json_response(200) == %{"repos" => []}

    heads =
      for name <- ["c", "a", "b"] do
        {:ok, head} = Repositories.create("did:plc:" <> name, SigningKey.generate())
        head
      end

    page = conn |> get(@list, %{limit: "2"}) |> json_response(200)
    assert Enum.map(page["repos"], & &1["did"]) == ["did:plc:a", "did:plc:b"]
    next = conn |> get(@list, %{limit: "2", cursor: page["cursor"]}) |> json_response(200)
    assert Enum.map(next["repos"], & &1["did"]) == ["did:plc:c"]
    refute Map.has_key?(next, "cursor")

    for row <- page["repos"] ++ next["repos"] do
      expected = Enum.find(heads, &(&1.did == row["did"]))

      assert row == %{
               "did" => expected.did,
               "head" => CID.to_base32(expected.head),
               "rev" => expected.rev,
               "active" => true
             }
    end
  end

  @collection_list "/xrpc/com.atproto.sync.listReposByCollection"

  test "collection discovery deduplicates, paginates and follows writes and account status", %{
    conn: conn
  } do
    collection = "com.example.record"

    assert conn |> get(@collection_list, %{collection: collection}) |> json_response(200) == %{
             "repos" => []
           }

    key = SigningKey.generate()

    for name <- ["c", "b", "a", "d"] do
      did = "did:plc:" <> name
      {:ok, _} = Repositories.create(did, key)

      {:ok, _} =
        Repositories.apply_writes(
          did,
          [
            {:put, collection <> "/one", %{"$type" => collection}},
            {:put, collection <> "/two", %{"$type" => collection}},
            {:put, "com.example.other/one", %{"$type" => "com.example.other"}}
          ],
          key
        )
    end

    {:ok, _} = Repositories.set_status("did:plc:b", :deactivated)
    {:ok, _} = Repositories.set_status("did:plc:d", :takendown)

    page =
      conn |> get(@collection_list, %{collection: collection, limit: "1"}) |> json_response(200)

    assert page == %{"repos" => [%{"did" => "did:plc:a"}], "cursor" => "did:plc:a"}

    assert conn
           |> get(@collection_list, %{collection: collection, limit: "1", cursor: page["cursor"]})
           |> json_response(200) == %{"repos" => [%{"did" => "did:plc:c"}]}

    assert conn |> get(@collection_list, %{collection: "com.example.rec"}) |> json_response(200) ==
             %{"repos" => []}

    assert conn
           |> get(@collection_list, %{collection: collection, cursor: "did:plc:z"})
           |> json_response(200) == %{"repos" => []}

    {:ok, _} = Repositories.apply_writes("did:plc:a", [{:delete, collection <> "/one"}], key)

    assert length(
             (conn
              |> get(@collection_list, %{collection: collection})
              |> json_response(200))["repos"]
           ) == 2

    {:ok, _} = Repositories.apply_writes("did:plc:a", [{:delete, collection <> "/two"}], key)
    {:ok, _} = Repositories.set_status("did:plc:b", :active)

    assert conn
           |> get(@collection_list, %{collection: collection, limit: "2000"})
           |> json_response(200) == %{
             "repos" => [%{"did" => "did:plc:b"}, %{"did" => "did:plc:c"}]
           }
  end

  test "collection discovery enforces the vendored query contract and read method", %{conn: conn} do
    for query <- [
          "",
          "collection=bad",
          "collection=com.example.record&limit=0",
          "collection=com.example.record&limit=2001",
          "collection=com.example.record&limit=1junk",
          "collection=com.example.record&cursor=bad",
          "collection[]=com.example.record",
          "collection=com.example.record&collection=com.example.other"
        ] do
      assert %{"error" => "InvalidRequest"} =
               conn |> get(@collection_list <> "?" <> query) |> json_response(400)
    end

    assert post(conn, @collection_list).status == 405
  end

  test "rejects malformed query parameters and distinguishes unknown repositories", %{conn: conn} do
    for route <- [@latest, @status] do
      for params <- [%{}, %{did: "bad"}, %{did: ["did:plc:example"]}] do
        assert %{"error" => "InvalidRequest"} = conn |> get(route, params) |> json_response(400)
      end

      assert %{"error" => "RepoNotFound"} =
               conn |> get(route, %{did: "did:plc:missing"}) |> json_response(400)
    end

    for params <- [
          %{limit: "0"},
          %{limit: "1001"},
          %{limit: "10bad"},
          %{limit: ["5"]},
          %{cursor: "bad"}
        ] do
      assert %{"error" => "InvalidRequest"} = conn |> get(@list, params) |> json_response(400)
    end
  end
end
