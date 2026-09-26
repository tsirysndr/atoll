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
