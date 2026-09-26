defmodule Atoll.Repositories.EventRetentionTest do
  use Atoll.DataCase, async: false
  alias Atoll.CBOR
  alias Atoll.Repositories.{Event, EventRetention, Events}
  alias AtollWeb.RepoStreamSocket, as: Socket

  test "bounded prefix pruning stops at newer events even when later timestamps are older" do
    first = event(-7200)
    second = event(-7100)
    fresh = event(0)
    later_old = event(-7000)
    assert {:ok, %{deleted: 1, floor: floor}} = EventRetention.prune(1, 3600)
    assert floor == first.seq
    assert {:ok, %{deleted: 1, floor: floor}} = EventRetention.prune(1000, 3600)
    assert floor == second.seq
    assert {:ok, %{deleted: 0, floor: ^floor}} = EventRetention.prune(1000, 3600)
    assert {:error, :outdated_cursor} = Events.list_after(first.seq)
    assert {:ok, rows} = Events.list_after(second.seq)
    assert Enum.map(rows, & &1.seq) == [fresh.seq, later_old.seq]
  end

  test "empty retained streams keep their last sequence and accept new events above the floor" do
    last = event(-7200)
    assert {:ok, %{deleted: 1, floor: floor}} = EventRetention.prune(1000, 3600)
    assert floor == last.seq
    assert Events.latest_seq() == last.seq
    assert EventRetention.bounds() == %{floor: floor, latest: floor}
    assert {:ok, []} = Events.list_after(floor)
    assert {:ok, state} = Socket.init({:ok, nil})
    assert state.cursor == floor
    Socket.terminate(:normal, state)
    next = event(0)
    assert next.seq > floor
    assert {:ok, [%{seq: seq}]} = Events.list_after(floor)
    assert seq == next.seq
  end

  test "expired resume cursors receive info before replay; zero explicitly starts at retained history" do
    first = event(-7200)
    second = event(-7100)
    retained = event(0)
    assert {:ok, _} = EventRetention.prune(1000, 3600)
    assert {:push, {:binary, notice}, state} = Socket.init({:ok, first.seq})
    assert_info(notice)
    assert state.cursor == second.seq
    assert {:push, {:binary, _}, next} = Socket.handle_info(:drain, state)
    assert next.cursor == retained.seq
    Socket.terminate(:normal, next)

    for cursor <- [0, second.seq] do
      assert {:ok, state} = Socket.init({:ok, cursor})
      assert state.cursor == second.seq
      Socket.terminate(:normal, state)
    end
  end

  test "connected subscribers notice retention advancing past them" do
    first = event(-7200)
    last = event(-7100)
    assert {:ok, state} = Socket.init({:ok, first.seq})
    assert {:ok, _} = EventRetention.prune(1000, 3600)
    assert {:push, {:binary, notice}, next} = Socket.handle_info(:drain, state)
    assert_info(notice)
    assert next.cursor == last.seq
    Socket.terminate(:normal, next)
    assert {:error, :outdated_cursor} = Events.next_frame(first.seq)
  end

  test "rollback preserves events and floor and invalid options perform no work" do
    row = event(-7200)

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, %{deleted: 1}} = EventRetention.prune(1000, 3600)
               Repo.rollback(:cancelled)
             end)

    assert Repo.get!(Event, row.seq)
    assert EventRetention.bounds().floor == 0

    for {limit, seconds} <- [{0, 3600}, {1001, 3600}, {1, 3599}, {1, 31_536_001}, {"1", 3600}] do
      assert {:error, :invalid_retention_options} = EventRetention.prune(limit, seconds)
    end
  end

  test "operator command prints counts and lossless floor, rejecting duplicate flags" do
    row = event(-7200)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Atoll.Events.Prune.run(["--limit", "1", "--retention-seconds", "3600"])
      end)

    assert Jason.decode!(output) == %{"deleted" => 1, "cursorFloor" => Integer.to_string(row.seq)}

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Atoll.Events.Prune.run(["--limit", "1", "--limit", "2"])
    end
  end

  defp event(offset) do
    Repo.insert!(%Event{
      did: "did:plc:retention",
      kind: :account,
      payload: CBOR.encode!(%{"active" => true}),
      time: DateTime.add(DateTime.utc_now(), offset, :second)
    })
  end

  defp assert_info(frame) do
    header = CBOR.encode!(%{"op" => 1, "t" => "#info"})
    size = byte_size(header)
    assert <<^header::binary-size(size), body::binary>> = frame
    assert {:ok, %{"name" => "OutdatedCursor"}} = CBOR.decode(body)
  end
end
