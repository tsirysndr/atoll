defmodule Atoll.Accounts.SessionLimiterTest do
  use ExUnit.Case, async: true
  alias Atoll.Accounts.SessionLimiter

  test "isolates keys, denies excess, and resets exactly at the window boundary" do
    clock = start_supervised!({Agent, fn -> 0 end})

    server =
      start_supervised!({SessionLimiter, name: nil, clock: fn -> Agent.get(clock, & &1) end})

    assert SessionLimiter.check(:one, 2, server) == :ok
    assert SessionLimiter.check(:one, 2, server) == :ok
    assert SessionLimiter.check(:one, 2, server) == {:error, 300}
    assert SessionLimiter.check(:two, 2, server) == :ok
    Agent.update(clock, fn _ -> 299_999 end)
    assert SessionLimiter.check(:one, 2, server) == {:error, 1}
    Agent.update(clock, fn _ -> 300_000 end)
    assert SessionLimiter.check(:one, 2, server) == :ok
  end

  test "bounds memory and sweeps expired keys" do
    clock = start_supervised!({Agent, fn -> 0 end})

    server =
      start_supervised!(
        {SessionLimiter, name: nil, capacity: 2, clock: fn -> Agent.get(clock, & &1) end}
      )

    assert SessionLimiter.check(:one, 1, server) == :ok
    assert SessionLimiter.check(:two, 1, server) == :ok
    assert SessionLimiter.check(:three, 1, server) == {:error, 300}
    assert map_size(:sys.get_state(server).entries) == 2
    Agent.update(clock, fn _ -> 300_000 end)
    send(server, :sweep)
    assert SessionLimiter.check(:three, 1, server) == :ok
    assert map_size(:sys.get_state(server).entries) == 1
  end
end
