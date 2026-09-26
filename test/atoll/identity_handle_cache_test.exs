defmodule Atoll.IdentityHandleCacheTest do
  use ExUnit.Case, async: true
  alias Atoll.Identity.{Cache, Handle}
  @handle "alice.example.com"
  @did "did:web:alice.example.com"
  @other "did:web:other.example.com"

  setup do
    clock = start_supervised!({Agent, fn -> 0 end})
    cache = start_supervised!({Cache, ttl_ms: 1000, clock: fn -> Agent.get(clock, & &1) end})
    %{cache: cache, clock: clock}
  end

  test "normalizes keys, expires positive claims, and does not cache ambiguous claims", c do
    assert Handle.resolve("Alice.Example.Com", options(c, @did)) == {:ok, @did}
    blocked = [handle_cache: c.cache, txt_lookup: fn _ -> flunk("unexpected DNS") end]
    assert Handle.resolve(@handle, blocked) == {:ok, @did}
    Agent.update(c.clock, fn _ -> 1000 end)

    ambiguous = [
      handle_cache: c.cache,
      txt_lookup: fn _ -> [["did=" <> @did], ["did=" <> @other]] end
    ]

    assert Handle.resolve(@handle, ambiguous) == {:error, :ambiguous_handle}
    assert Handle.resolve(@handle, options(c, @other)) == {:ok, @other}
  end

  test "forced failed refresh evicts the old claim instead of falling back", c do
    assert Handle.resolve(@handle, options(c, @did)) == {:ok, @did}

    opts = [
      handle_cache: c.cache,
      force_refresh: true,
      txt_lookup: fn _ -> [] end,
      lookup: fn _ -> {:error, :unavailable} end
    ]

    assert Handle.resolve(@handle, opts) == {:error, :handle_not_found}
    assert Handle.resolve(@handle, options(c, @other)) == {:ok, @other}
  end

  test "an older in-flight handle result cannot overwrite a newer forced claim", c do
    supervisor = start_supervised!({Task.Supervisor, []})
    parent = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Handle.resolve(@handle,
          handle_cache: c.cache,
          txt_lookup: fn _ ->
            send(parent, :fetching)

            receive do
              :finish -> [["did=" <> @did]]
            end
          end
        )
      end)

    assert_receive :fetching

    assert Handle.resolve(@handle, Keyword.put(options(c, @other), :force_refresh, true)) ==
             {:ok, @other}

    send(task.pid, :finish)
    assert Task.await(task) == {:ok, @did}
    assert Handle.resolve(@handle, options(c, @did)) == {:ok, @other}
  end

  test "cache outages and a disabled cache still perform authoritative resolution", c do
    GenServer.stop(c.cache)
    assert Handle.resolve(@handle, options(c, @did)) == {:ok, @did}

    assert Handle.resolve(@handle,
             handle_cache: false,
             txt_lookup: fn _ -> [["did=" <> @other]] end
           ) == {:ok, @other}
  end

  test "bounded entries evict old claims and zero TTL disables reuse" do
    cache = start_supervised!({Cache, max_entries: 1}, id: :bounded)
    assert Handle.resolve(@handle, options(%{cache: cache}, @did)) == {:ok, @did}
    assert Handle.resolve("other.example.com", options(%{cache: cache}, @other)) == {:ok, @other}
    assert Handle.resolve(@handle, options(%{cache: cache}, @other)) == {:ok, @other}
    zero = start_supervised!({Cache, ttl_ms: 0}, id: :zero)
    assert Handle.resolve(@handle, options(%{cache: zero}, @did)) == {:ok, @did}
    assert Handle.resolve(@handle, options(%{cache: zero}, @other)) == {:ok, @other}
  end

  defp options(c, did), do: [handle_cache: c.cache, txt_lookup: fn _ -> [["did=" <> did]] end]
end
