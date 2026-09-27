defmodule AtollWeb.StreamConnectionsTest do
  use ExUnit.Case, async: true
  alias AtollWeb.StreamConnections, as: Quota

  setup do
    server = start_supervised!({Quota, name: nil, limits: fn -> {3, 2} end})
    %{server: server}
  end

  test "pending and active leases share per-peer and total quotas", %{server: server} do
    assert {:ok, first} = Quota.reserve(:one, server)
    assert :ok = Quota.claim(first)
    assert {:ok, second} = Quota.reserve(:one, server)
    assert {:error, :full} = Quota.reserve(:one, server)
    assert {:ok, third} = Quota.reserve(:two, server)
    assert {:error, :full} = Quota.reserve(:three, server)
    Quota.release(second)
    assert {:ok, fourth} = Quota.reserve(:three, server)
    assert {:error, :unavailable} = Quota.claim(first)
    for lease <- [first, third, fourth], do: Quota.release(lease)
    assert %{entries: entries, peers: peers, monitors: monitors} = :sys.get_state(server)
    assert entries == %{} and peers == %{} and monitors == %{}
  end

  test "pending expiry cannot remove a claimed lease", %{server: server} do
    {:ok, {_, pending} = lease} = Quota.reserve(:one, server)
    send(server, {:expire, pending})
    assert {:error, :unavailable} = Quota.claim(lease)
    {:ok, {_, active} = lease} = Quota.reserve(:one, server)
    assert :ok = Quota.claim(lease)
    send(server, {:expire, active})
    assert map_size(:sys.get_state(server).entries) == 1
    Quota.release(lease)
    assert :sys.get_state(server).entries == %{}
  end

  test "ownership handoff survives old-owner cleanup and new-owner death frees capacity", %{
    server: server
  } do
    parent = self()

    task =
      start_supervised!(
        {Task,
         fn ->
           {:ok, lease} = Quota.reserve(:one, server)
           send(parent, {:lease, lease})

           receive do
             :done -> :ok
           end
         end}
      )

    assert_receive {:lease, lease}
    assert :ok = Quota.claim(lease)
    monitor = Process.monitor(task)
    send(task, :done)
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}
    assert map_size(:sys.get_state(server).entries) == 1
    Quota.release(lease)
    assert :sys.get_state(server).entries == %{}

    task =
      start_supervised!(
        {Task,
         fn ->
           {:ok, lease} = Quota.reserve(:two, server)
           :ok = Quota.claim(lease)
           send(parent, {:owned, lease})

           receive do
             :done -> :ok
           end
         end},
        id: :second
      )

    assert_receive {:owned, _lease}
    monitor = Process.monitor(task)
    send(task, :done)
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}
    assert :sys.get_state(server).entries == %{}
  end

  test "unavailable quota servers fail closed" do
    task = start_supervised!({Task, fn -> :ok end})
    monitor = Process.monitor(task)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}
    assert {:error, :unavailable} = Quota.reserve(:one, task)
  end

  test "concurrent admission cannot exceed the live total or per-peer bound", %{server: server} do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    tasks =
      for n <- 1..12 do
        Task.Supervisor.async_nolink(supervisor, fn ->
          peer = rem(n, 2)
          result = Quota.reserve(peer, server)
          send(parent, {:admitted, peer, result})

          receive do
            :finish -> :ok
          end
        end)
      end

    results =
      for _ <- tasks do
        assert_receive {:admitted, peer, result}
        {peer, result}
      end

    accepted = Enum.filter(results, fn {_, result} -> match?({:ok, _}, result) end)
    assert length(accepted) == 3
    assert Enum.all?(Enum.frequencies_by(accepted, &elem(&1, 0)), fn {_, count} -> count <= 2 end)
    assert map_size(:sys.get_state(server).entries) == 3
    for task <- tasks, do: send(task.pid, :finish)
    for task <- tasks, do: Task.await(task)
  end

  test "invalid application limits fail closed" do
    server = start_supervised!({Quota, name: nil, limits: fn -> {0, "bad"} end}, id: :invalid)
    assert {:error, :unavailable} = Quota.reserve(:one, server)
    assert :sys.get_state(server).entries == %{}
  end

  test "configuration parser rejects disabling and malformed budgets" do
    assert Quota.limit_from_env!("1") == 1
    assert Quota.limit_from_env!("100000") == 100_000

    for value <- ["0", "-1", "bad", "100001", "1tail", ""] do
      assert_raise ArgumentError, fn -> Quota.limit_from_env!(value) end
    end
  end
end
