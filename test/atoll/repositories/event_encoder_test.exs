defmodule Atoll.Repositories.EventEncoderTest do
  use Atoll.DataCase, async: true
  alias Atoll.{CAR, CBOR, Commit, MST, Repositories, SigningKey, Storage}
  alias Atoll.CBOR.{Bytes, Link}
  alias Atoll.Repositories.{EventEncoder, Events}

  @did "did:plc:eventencoder"
  @collection "com.example.record"

  setup do
    key = SigningKey.generate()
    {:ok, _} = Repositories.create(@did, key)
    %{key: key}
  end

  test "historical commits verify and operations invert after later writes", %{key: key} do
    first = for i <- 1..20, do: {:put, "#{@collection}/#{i}", value("initial #{i}")}
    {:ok, _} = Repositories.apply_writes(@did, first, key)

    {:ok, _} =
      Repositories.apply_writes(
        @did,
        [
          {:put, "#{@collection}/1", value("replacement")},
          {:delete, "#{@collection}/2"},
          {:put, "#{@collection}/new", value("new")}
        ],
        key
      )

    {:ok, _} = Repositories.apply_writes(@did, [{:delete, "#{@collection}/missing"}], key)
    {:ok, events} = Events.list_after(0)

    Enum.reduce(events, nil, fn event, previous_root ->
      assert {:ok, "#commit", body} = EventEncoder.message(event)
      assert body["seq"] == event.seq
      assert body["time"] == DateTime.to_iso8601(event.time)
      assert body["tooBig"] == false
      assert body["rebase"] == false
      assert body["blobs"] == []
      assert {:ok, %{roots: [cid], blocks: blocks}} = CAR.decode(body["blocks"].data)
      assert %Link{cid: ^cid} = body["commit"]
      assert {:ok, commit} = Commit.verify(blocks[cid], @did, key.curve, key.public)
      assert commit["rev"] == body["rev"]
      assert {:ok, tree} = MST.load(commit["data"].cid, blocks)

      old_records =
        Enum.reduce(body["ops"], tree.records, fn op, acc ->
          case op["action"] do
            "create" ->
              refute Map.has_key?(op, "prev")
              assert Map.has_key?(blocks, op["cid"].cid)
              Map.delete(acc, op["path"])

            "update" ->
              assert Map.has_key?(blocks, op["cid"].cid)
              Map.put(acc, op["path"], op["prev"].cid)

            "delete" ->
              assert op["cid"] == nil
              Map.put(acc, op["path"], op["prev"].cid)
          end
        end)

      if previous_root do
        assert body["prevData"] == %Link{cid: previous_root}
        assert {:ok, inverted} = MST.new(old_records)
        assert inverted.root == previous_root
      else
        refute Map.has_key?(body, "prevData")
        assert body["since"] == nil
      end

      commit["data"].cid
    end)

    assert {:ok, "#commit", %{"ops" => []}} = EventEncoder.message(List.last(events))
  end

  test "encodes exactly two CBOR objects with the protocol header" do
    {:ok, [event]} = Events.list_after(0)
    {:ok, "#commit", body} = EventEncoder.message(event)
    assert {:ok, frame} = EventEncoder.encode(event)
    # Fixed independently known encoding of {"t": "#commit", "op": 1}.
    header = <<0xA2, 0x61, "t", 0x67, "#commit", 0x62, "op", 1>>
    assert <<^header::binary-size(byte_size(header)), payload::binary>> = frame
    assert CBOR.decode(payload) == {:ok, body}
  end

  test "oversized commits produce a small commit-only sync message", %{key: key} do
    cursor = Events.latest_seq()

    ops =
      for i <- 1..3,
          do: {:put, "#{@collection}/#{i}", value(String.duplicate("x", 700_000) <> "#{i}")}

    {:ok, head} = Repositories.apply_writes(@did, ops, key)
    {:ok, [event]} = Events.list_after(cursor)
    assert {:ok, "#sync", body} = EventEncoder.message(event)
    assert body["did"] == @did
    assert body["rev"] == head.rev
    assert %Bytes{data: car} = body["blocks"]
    assert byte_size(car) <= 10_000
    assert {:ok, %{roots: [cid], blocks: blocks}} = CAR.decode(car)
    assert cid == head.head
    assert Map.keys(blocks) == [cid]
    assert {:ok, _} = Commit.verify(blocks[cid], @did, key.curve, key.public)
  end

  test "account events omit the status when active" do
    cursor = Events.latest_seq()
    {:ok, _} = Repositories.set_status(@did, :suspended)
    {:ok, _} = Repositories.set_status(@did, :active)
    {:ok, [suspended, active]} = Events.list_after(cursor)

    assert {:ok, "#account", %{"active" => false, "status" => "suspended", "did" => @did}} =
             EventEncoder.message(suspended)

    assert {:ok, "#account", body} = EventEncoder.message(active)
    assert body["active"]
    refute Map.has_key?(body, "status")
  end

  test "missing and corrupt historical blocks fail closed" do
    {:ok, [event]} = Events.list_after(0)
    missing = Atoll.CID.create("not stored", :dag_cbor)
    invalid = put_in(event, [:payload, "commit"], %Link{cid: missing})
    assert EventEncoder.encode(invalid) == {:error, :invalid_event_blocks}
    cid = event.payload["commit"].cid
    {:ok, commit} = Storage.get_node(cid)
    root = commit["data"].cid
    Repo.update_all(from(b in Atoll.Storage.Block, where: b.cid == ^root), set: [data: "corrupt"])
    assert EventEncoder.encode(event) == {:error, :invalid_event_blocks}
  end

  test "error frame has op -1 and no type" do
    assert <<0xA1, 0x62, "op", 0x20, body::binary>> =
             EventEncoder.error("FutureCursor", "Cursor is in the future")

    assert CBOR.decode(body) ==
             {:ok, %{"error" => "FutureCursor", "message" => "Cursor is in the future"}}
  end

  defp value(text), do: %{"$type" => @collection, "text" => text}
end
