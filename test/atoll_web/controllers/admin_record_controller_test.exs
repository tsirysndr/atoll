defmodule AtollWeb.AdminRecordControllerTest do
  use AtollWeb.ConnCase, async: false
  alias Atoll.{CAR, CID, KeyVault, Repo, Repositories, SigningKey}
  alias Atoll.Accounts.Sessions
  alias Atoll.Repositories.Events
  @did "did:web:record-moderation.example.com"
  @collection "com.example.record"
  @path @collection <> "/b"
  @uri "at://" <> @did <> "/" <> @path
  @get "/xrpc/com.atproto.admin.getSubjectStatus"
  @update "/xrpc/com.atproto.admin.updateSubjectStatus"
  @secret "independent-operator-secret-for-record-tests"

  setup %{conn: conn} do
    previous =
      Map.new(
        [:admin_password, :session_signing_key, :key_encryption_key],
        &{&1, Application.fetch_env(:atoll, &1)}
      )

    Application.put_env(:atoll, :admin_password, @secret)

    for key <- [:session_signing_key, :key_encryption_key],
        do: Application.put_env(:atoll, key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:atoll, key, value)
          :error -> Application.delete_env(:atoll, key)
        end
      end
    end)

    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    {:ok, :stored} = KeyVault.store(@did, key)
    {:ok, pair} = Sessions.create_for_account(@did)
    before_write = Events.latest_seq()

    {:ok, head} =
      Repositories.apply_writes(
        @did,
        Enum.map(~w(a b c), &{:put, @collection <> "/" <> &1, value(&1)}),
        key
      )

    {:ok, record} = Repositories.get_record(@did, @path)

    subject = %{
      "$type" => "com.atproto.repo.strongRef",
      "uri" => @uri,
      "cid" => CID.to_base32(record.cid)
    }

    id = rem(System.unique_integer([:positive]), 65_536)

    %{
      conn: %{conn | remote_ip: {10, 62, div(id, 256), rem(id, 256)}},
      key: key,
      pair: pair,
      head: head,
      subject: subject,
      cid: record.cid,
      before_write: before_write
    }
  end

  test "record API visibility is separate from signed sync exports and public events", c do
    {:ok, archive} = Repositories.export(@did)
    {:ok, frame} = Events.next_frame(c.before_write)
    seq = Events.latest_seq()

    assert %{"subject" => subject, "takedown" => %{"applied" => false}} =
             status(c) |> json_response(200)

    assert subject == c.subject

    assert update(c, c.subject, %{applied: true, ref: "private-case"}) |> json_response(200) ==
             %{
               "subject" => c.subject,
               "takedown" => %{"applied" => true, "ref" => "private-case"}
             }

    assert update(c, c.subject, %{applied: true, ref: "private-case"}) |> json_response(200)
    assert %{"error" => "RecordNotFound"} = read(c) |> json_response(400)
    assert read(c, %{cid: CID.to_base32(c.cid)}) |> json_response(400)
    assert {:ok, _} = Repositories.get_record(@did, @collection <> "/a")
    assert {:ok, ^archive} = Repositories.export(@did)
    assert {:ok, ^frame} = Events.next_frame(c.before_write)
    assert {:ok, %{blocks: blocks}} = CAR.decode(archive)
    assert Map.has_key?(blocks, c.cid)
    assert {:ok, _} = Repositories.export_record(@did, @path)
    assert {:ok, _} = Repositories.export_blocks(@did, [c.cid])
    assert Repositories.get_head(@did) == {:ok, c.head}
    assert Events.latest_seq() == seq
    update(c, c.subject, %{applied: false}) |> json_response(200)
    assert read(c) |> json_response(200)
    refute (status(c) |> json_response(200))["takedown"]["applied"]
    assert Events.latest_seq() == seq
  end

  test "pagination excludes moderated paths before applying the page limit in either direction",
       c do
    update(c, c.subject, %{applied: true}) |> json_response(200)

    for reverse <- [false, true] do
      first = list(c, %{limit: "1", reverse: to_string(reverse)}) |> json_response(200)

      second =
        list(c, %{limit: "1", reverse: to_string(reverse), cursor: first["cursor"]})
        |> json_response(200)

      keys =
        Enum.map(first["records"] ++ second["records"], &List.last(String.split(&1["uri"], "/")))

      assert keys == if(reverse, do: ["a", "c"], else: ["c", "a"])
      refute Map.has_key?(second, "cursor")
    end

    {:ok, _} =
      Repositories.apply_writes(@did, [{:put, @collection <> "/copy", value("b")}], c.key)

    assert {:ok, %{cid: cid}} = Repositories.get_record(@did, @collection <> "/copy")
    assert cid == c.cid
    other = "did:web:unaffected-record.example.com"
    {:ok, _} = Repositories.create(other, c.key)
    {:ok, _} = Repositories.apply_writes(other, [{:put, @path, value("b")}], c.key)
    assert {:ok, _} = Repositories.get_record(other, @path)
  end

  test "owner edits and deletion do not erase the URI restriction, and stale operator decisions fail",
       c do
    update(c, c.subject, %{applied: true}) |> json_response(200)

    result =
      owner(c, "putRecord", %{
        repo: @did,
        collection: @collection,
        rkey: "b",
        record: value("corrected")
      })
      |> json_response(200)

    assert result["cid"] != c.subject["cid"]
    assert read(c) |> json_response(400)
    assert read(c, %{cid: c.subject["cid"]}) |> json_response(400)
    stale = update(c, c.subject, %{applied: false}) |> json_response(400)
    assert stale["error"] == "InvalidSwap"
    latest = status(c) |> json_response(200)
    assert latest["subject"]["cid"] == result["cid"]
    assert latest["takedown"]["applied"]

    owner(c, "deleteRecord", %{repo: @did, collection: @collection, rkey: "b"})
    |> json_response(200)

    retained = status(c) |> json_response(200)
    assert retained["takedown"]["applied"]

    owner(c, "createRecord", %{
      repo: @did,
      collection: @collection,
      rkey: "b",
      record: value("recreated")
    })
    |> json_response(200)

    assert read(c) |> json_response(400)
    latest = status(c) |> json_response(200)
    update(c, latest["subject"], %{applied: false}) |> json_response(200)
    assert (read(c) |> json_response(200))["value"]["text"] == "recreated"
  end

  test "imports keep URI restrictions, even when the imported record has changed", c do
    update(c, c.subject, %{applied: true}) |> json_response(200)
    record = Atoll.CBOR.encode!(value("imported"))
    cid = CID.create(record, :dag_cbor)
    {:ok, tree} = Atoll.MST.new(%{@path => cid})
    {:ok, rev} = Atoll.TID.next(c.head.rev)
    {:ok, commit} = Atoll.Commit.create(@did, tree.root, rev, c.key)

    {:ok, archive} =
      CAR.encode(
        [commit.cid],
        tree.blocks |> Map.put(cid, record) |> Map.put(commit.cid, commit.bytes)
      )

    assert {:ok, _} = Repositories.import_archive(@did, archive, c.head.head)
    assert read(c) |> json_response(400)
    assert (list(c, %{}) |> json_response(200))["records"] == []
    latest = status(c) |> json_response(200)
    assert latest["subject"]["cid"] == CID.to_base32(cid)
    update(c, latest["subject"], %{applied: false}) |> json_response(200)
    assert (read(c) |> json_response(200))["value"]["text"] == "imported"
  end

  test "validation, authorization, missing subjects and rollback never falsely apply a restriction",
       c do
    assert get(c.conn, @get, %{uri: @uri}) |> json_response(401)

    assert c.conn
           |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
           |> get(@get, %{uri: @uri})
           |> json_response(401)

    for subject <- [
          Map.put(c.subject, "uri", "at://example.com/com.example.record/b"),
          Map.put(c.subject, "uri", "at://#{@did}/com.example.record/.."),
          Map.put(c.subject, "cid", CID.to_base32(CID.create("blob", :raw))),
          Map.put(c.subject, "extra", true)
        ],
        do: assert(update(c, subject, %{applied: true}) |> json_response(400))

    assert update(c, c.subject, %{applied: true, ref: String.duplicate("a", 2001)})
           |> json_response(400)

    missing = Map.put(c.subject, "uri", "at://#{@did}/com.example.record/missing")
    assert %{"error" => "NotFound"} = update(c, missing, %{applied: true}) |> json_response(400)

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        Atoll.Accounts.SubjectStatus.update(%{
                          "subject" => c.subject,
                          "takedown" => %{"applied" => true}
                        })

               Repo.rollback(:cancelled)
             end)

    assert Repo.aggregate(Atoll.Repositories.Takedown, :count) == 0
    assert {:ok, _} = Repositories.get_record(@did, @path)
    # Administrators can still review and lift restrictions while an account is inactive.
    update(c, c.subject, %{applied: true}) |> json_response(200)
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert (status(c) |> json_response(200))["takedown"]["applied"]
    update(c, c.subject, %{applied: false}) |> json_response(200)
    assert {:ok, %{status: :deactivated}} = Repositories.get_head(@did)
  end

  test "a retained restriction can be lifted after the record has been deleted", c do
    update(c, c.subject, %{applied: true}) |> json_response(200)
    {:ok, _} = Repositories.apply_writes(@did, [{:delete, @path}], c.key)
    assert (status(c) |> json_response(200))["subject"] == c.subject
    assert update(c, c.subject, %{applied: false}) |> json_response(200)

    assert status(c) |> json_response(400) == %{
             "error" => "NotFound",
             "message" => "Subject not found."
           }

    assert Repo.aggregate(Atoll.Repositories.Takedown, :count) == 0
  end

  defp value(text), do: %{"$type" => @collection, "text" => text}

  defp auth(conn),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("admin:" <> @secret))

  defp status(c), do: auth(c.conn) |> get(@get, %{uri: @uri})

  defp update(c, subject, attr),
    do:
      auth(c.conn)
      |> put_req_header("content-type", "application/json")
      |> post(@update, Jason.encode!(%{subject: subject, takedown: attr}))

  defp read(c, opts \\ %{}),
    do:
      get(
        c.conn,
        "/xrpc/com.atproto.repo.getRecord",
        Map.merge(%{repo: @did, collection: @collection, rkey: "b"}, opts)
      )

  defp list(c, opts),
    do:
      get(
        c.conn,
        "/xrpc/com.atproto.repo.listRecords",
        Map.merge(%{repo: @did, collection: @collection}, opts)
      )

  defp owner(c, method, body),
    do:
      c.conn
      |> put_req_header("authorization", "Bearer " <> c.pair.access_jwt)
      |> put_req_header("content-type", "application/json")
      |> post("/xrpc/com.atproto.repo." <> method, Jason.encode!(body))
end
