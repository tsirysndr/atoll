defmodule AtollWeb.RepositoryStatusTest do
  use AtollWeb.ConnCase, async: true
  alias Atoll.{CID, Repositories, SigningKey}
  @did "did:web:alice.example.com"
  @collection "com.example.record"

  setup do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)

    {:ok, head} =
      Repositories.apply_writes(
        @did,
        [{:put, @collection <> "/self", %{"$type" => @collection}}],
        key
      )

    {:ok, archive} = Repositories.export(@did)
    %{key: key, head: head, archive: archive}
  end

  test "inactive repositories deny public data and mutations while reporting status", %{
    conn: conn,
    key: key,
    head: head,
    archive: archive
  } do
    for {status, error} <- [
          deactivated: "RepoDeactivated",
          takendown: "RepoTakendown",
          suspended: "RepoSuspended"
        ] do
      assert {:ok, changed} = Repositories.set_status(@did, status)
      assert changed.head == head.head and changed.rev == head.rev

      for {method, params} <- [
            {"repo.getRecord", %{repo: @did, collection: @collection, rkey: "self"}},
            {"repo.listRecords", %{repo: @did, collection: @collection}},
            {"repo.describeRepo", %{repo: @did}},
            {"sync.getRepo", %{did: @did}},
            {"sync.getRecord", %{did: @did, collection: @collection, rkey: "self"}},
            {"sync.getBlocks", %{did: @did, cids: CID.to_base32(head.head)}},
            {"sync.getLatestCommit", %{did: @did}}
          ] do
        assert %{"error" => ^error} =
                 conn |> get("/xrpc/com.atproto." <> method, params) |> json_response(400)
      end

      expected = %{"did" => @did, "active" => false, "status" => Atom.to_string(status)}

      assert conn
             |> get("/xrpc/com.atproto.sync.getRepoStatus", %{did: @did})
             |> json_response(200) == expected

      assert %{"repos" => [repo]} =
               conn |> get("/xrpc/com.atproto.sync.listRepos") |> json_response(200)

      assert repo["active"] == false and repo["status"] == Atom.to_string(status)
      assert repo["head"] == CID.to_base32(head.head)

      assert Repositories.apply_writes(@did, [{:delete, @collection <> "/self"}], key) ==
               {:error, {:repo_inactive, status}}

      assert Repositories.import_archive(@did, archive, head.head) ==
               {:error, {:repo_inactive, status}}
    end
  end

  test "reactivation restores records, exports and status without changing the commit", %{
    conn: conn,
    head: head,
    archive: archive
  } do
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert {:ok, active} = Repositories.set_status(@did, :active)
    assert active.head == head.head
    assert Repositories.export(@did) == {:ok, archive}

    assert %{"value" => %{"$type" => @collection}} =
             conn
             |> get("/xrpc/com.atproto.repo.getRecord", %{
               repo: @did,
               collection: @collection,
               rkey: "self"
             })
             |> json_response(200)

    assert %{"active" => true, "rev" => rev} =
             conn
             |> get("/xrpc/com.atproto.sync.getRepoStatus", %{did: @did})
             |> json_response(200)

    assert rev == head.rev
  end

  test "rejects invalid status and missing repository without altering existing state", %{
    head: head
  } do
    assert Repositories.set_status(@did, "active") == {:error, :invalid_status}
    assert Repositories.set_status(@did, :deleted) == {:error, :invalid_status}

    assert Repositories.set_status("did:web:missing.example.com", :deactivated) ==
             {:error, :not_found}

    assert Repositories.get_head(@did) == {:ok, head}
  end
end
