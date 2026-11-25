defmodule Atoll.Repositories.StreamBoundsTest do
  use ExUnit.Case, async: true
  alias Atoll.Repositories.StreamBounds

  test "many subscribers share a query, including failures, and recover after expiry" do
    clock = start_supervised!({Agent, fn -> 0 end})
    owner = self()

    cache =
      start_supervised!(
        {StreamBounds,
         name: nil,
         clock: fn -> Agent.get(clock, & &1) end,
         fetch: fn ->
           now = Agent.get(clock, & &1)
           send(owner, {:fetch, now})
           if now < 500, do: {:error, :database_busy}, else: {:ok, %{floor: 2, latest: 10}}
         end}
      )

    tasks = start_supervised!(Task.Supervisor)

    pending =
      for _ <- 1..100,
          do: Task.Supervisor.async_nolink(tasks, fn -> GenServer.call(cache, :get) end)

    assert Enum.all?(pending, &(Task.await(&1) == {:error, :database_busy}))
    assert_receive {:fetch, 0}
    refute_receive {:fetch, _}
    Agent.update(clock, fn _ -> 500 end)
    assert GenServer.call(cache, :get) == {:ok, %{floor: 2, latest: 10}}
    assert_receive {:fetch, 500}
    assert GenServer.call(cache, :get) == {:ok, %{floor: 2, latest: 10}}
    refute_receive {:fetch, _}
  end
end
