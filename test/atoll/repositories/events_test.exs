defmodule Atoll.Repositories.EventsTest do
  use Atoll.DataCase, async: true
  alias Atoll.{CBOR, Repositories, SigningKey}
  alias Atoll.Repositories.Events

  @did "did:plc:events"
  @path "com.example.record/self"
  @value %{"$type" => "com.example.record", "text" => "hello"}

  test "replays immutable commit transitions with exclusive bounded cursors" do
    key = SigningKey.generate()
    {:ok, initial} = Repositories.create(@did, key)
    {:ok, created} = Repositories.apply_writes(@did, [{:put, @path, @value}], key)
    {:ok, record} = Repositories.get_record(@did, @path)

    {:ok, updated} =
      Repositories.apply_writes(@did, [{:put, @path, Map.put(@value, "text", "new")}], key)

    {:ok, next_record} = Repositories.get_record(@did, @path)
    {:ok, _} = Repositories.apply_writes(@did, [{:delete, @path}], key)
    {:ok, [first, second]} = Events.list_after(0, 2)
    assert first.did == @did
    assert first.kind == :commit
    assert first.payload["commit"] == %CBOR.Link{cid: initial.head}
    assert first.payload["since"] == nil
    assert first.payload["ops"] == []
    assert second.payload["rev"] == created.rev
    assert second.payload["since"] == initial.rev
    assert second.payload["previousCommit"] == %CBOR.Link{cid: initial.head}

    assert second.payload["ops"] == [
             %{
               "action" => "create",
               "path" => @path,
               "cid" => %CBOR.Link{cid: record.cid},
               "prev" => nil
             }
           ]

    {:ok, [third, fourth]} = Events.list_after(second.seq)
    assert third.payload["rev"] == updated.rev

    assert third.payload["ops"] == [
             %{
               "action" => "update",
               "path" => @path,
               "cid" => %CBOR.Link{cid: next_record.cid},
               "prev" => %CBOR.Link{cid: record.cid}
             }
           ]

    assert fourth.payload["ops"] == [
             %{
               "action" => "delete",
               "path" => @path,
               "cid" => nil,
               "prev" => %CBOR.Link{cid: next_record.cid}
             }
           ]

    assert first.seq < second.seq and second.seq < third.seq and third.seq < fourth.seq
    assert Events.latest_seq() == fourth.seq
    assert {:ok, []} = Events.list_after(fourth.seq)
  end

  test "outer rollback removes the event and repository together" do
    assert Events.latest_seq() == 0

    assert {:error, :abort} =
             Repo.transaction(fn ->
               {:ok, _} = Repositories.create(@did, SigningKey.generate())
               assert Events.latest_seq() > 0
               Repo.rollback(:abort)
             end)

    assert Events.latest_seq() == 0
    assert Repositories.get_head(@did) == {:error, :not_found}
  end

  test "failed writes and identical imports emit nothing; status retries are idempotent" do
    key = SigningKey.generate()
    {:ok, head} = Repositories.create(@did, key)
    seq = Events.latest_seq()

    assert {:error, :invalid_swap} =
             Repositories.apply_writes(@did, [{:put, @path, @value}], key, swap_commit: <<0>>)

    {:ok, archive} = Repositories.export(@did)
    assert {:ok, ^head} = Repositories.import_archive(@did, archive, head.head)
    assert Events.latest_seq() == seq
    assert {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert {:ok, _} = Repositories.set_status(@did, :active)
    assert {:ok, [inactive, active]} = Events.list_after(seq)
    assert inactive.kind == :account
    assert inactive.payload == %{"active" => false, "status" => "deactivated"}
    assert active.payload == %{"active" => true, "status" => "active"}
  end

  test "validates replay bounds" do
    for cursor <- [-1, "1", nil, 9_223_372_036_854_775_808] do
      assert Events.list_after(cursor) == {:error, :invalid_cursor_or_limit}
    end

    for limit <- [0, 1001, 1.5, "2"] do
      assert Events.list_after(0, limit) == {:error, :invalid_cursor_or_limit}
    end
  end
end
