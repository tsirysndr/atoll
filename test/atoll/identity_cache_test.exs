defmodule Atoll.IdentityCacheTest do
  use ExUnit.Case, async: true
  alias Atoll.Identity.{Cache, Resolver}
  @did "did:web:alice.example.com"

  setup do
    clock = start_supervised!({Agent, fn -> 0 end})
    cache = start_supervised!({Cache, clock: fn -> Agent.get(clock, & &1) end, ttl_ms: 1000})
    %{cache: cache, clock: clock}
  end

  test "positive results expire at the TTL boundary; errors and mismatched identities are not cached",
       c do
    doc = %{"id" => @did}
    assert {:ok, ^doc} = Cache.fetch(c.cache, @did, false, fn -> {:ok, doc} end)
    Agent.update(c.clock, fn _ -> 999 end)
    assert {:ok, ^doc} = Cache.fetch(c.cache, @did, false, fn -> flunk("cache miss") end)
    Agent.update(c.clock, fn _ -> 1000 end)

    assert {:error, :did_not_found} =
             Cache.fetch(c.cache, @did, false, fn -> {:error, :did_not_found} end)

    wrong = %{"id" => "did:web:other.example.com"}
    assert {:ok, ^wrong} = Cache.fetch(c.cache, @did, false, fn -> {:ok, wrong} end)
    assert {:ok, ^doc} = Cache.fetch(c.cache, @did, false, fn -> {:ok, doc} end)
  end

  test "forced refresh evicts old data even if the network fails", c do
    doc = %{"id" => @did}
    Cache.fetch(c.cache, @did, false, fn -> {:ok, doc} end)

    assert {:error, :resolution_failed} =
             Cache.fetch(c.cache, @did, true, fn -> {:error, :resolution_failed} end)

    newer = Map.put(doc, "alsoKnownAs", ["at://new.example.com"])
    assert {:ok, ^newer} = Cache.fetch(c.cache, @did, false, fn -> {:ok, newer} end)
  end

  test "an older in-flight fetch cannot overwrite a forced refresh", c do
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)
    old_doc = %{"id" => @did, "version" => 1}
    new_doc = %{"id" => @did, "version" => 2}

    old =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Cache.fetch(c.cache, @did, false, fn ->
          send(parent, :fetch_started)

          receive do
            :finish -> {:ok, old_doc}
          end
        end)
      end)

    assert_receive :fetch_started
    assert {:ok, ^new_doc} = Cache.fetch(c.cache, @did, true, fn -> {:ok, new_doc} end)
    send(old.pid, :finish)
    assert {:ok, ^old_doc} = Task.await(old)

    assert {:ok, ^new_doc} =
             Cache.fetch(c.cache, @did, false, fn -> flunk("old result replaced cache") end)
  end

  test "count and serialized payload budgets evict older entries" do
    cache = start_supervised!({Cache, max_entries: 2, max_bytes: 200}, id: :small_cache)

    for id <- 1..3 do
      did = "did:web:#{id}.example.com"
      assert {:ok, _} = Cache.fetch(cache, did, false, fn -> {:ok, %{"id" => did}} end)
    end

    assert {:error, :miss} =
             Cache.fetch(cache, "did:web:1.example.com", false, fn -> {:error, :miss} end)

    assert {:ok, _} =
             Cache.fetch(cache, "did:web:3.example.com", false, fn -> flunk("evicted newest") end)

    large = %{"id" => @did, "data" => String.duplicate("x", 201)}
    assert {:ok, ^large} = Cache.fetch(cache, @did, false, fn -> {:ok, large} end)
    assert {:error, :miss} = Cache.fetch(cache, @did, false, fn -> {:error, :miss} end)

    byte_cache = start_supervised!({Cache, max_entries: 10, max_bytes: 150}, id: :byte_cache)

    for did <- [@did, "did:web:bob.example.com"] do
      Cache.fetch(byte_cache, did, false, fn ->
        {:ok, %{"id" => did, "data" => String.duplicate("x", 60)}}
      end)
    end

    assert {:error, :miss} = Cache.fetch(byte_cache, @did, false, fn -> {:error, :miss} end)
  end

  test "disabled or unavailable cache leaves resolution operational" do
    cache = start_supervised!({Cache, ttl_ms: 0}, id: :disabled_cache)

    for version <- 1..2 do
      assert {:ok, %{"version" => ^version}} =
               Cache.fetch(cache, @did, false, fn ->
                 {:ok, %{"id" => @did, "version" => version}}
               end)
    end

    stop_supervised!(:disabled_cache)

    assert {:error, :authoritative_error} =
             Cache.fetch(cache, @did, false, fn -> {:error, :authoritative_error} end)
  end

  test "resolver caches only validated documents and explicit custom transports remain isolated",
       c do
    opts = [
      cache: c.cache,
      lookup: fn _ -> {:ok, {8, 8, 8, 8}} end,
      request: Req.new(plug: {Req.Test, __MODULE__})
    ]

    doc = %{"id" => @did, "alsoKnownAs" => ["at://alice.example.com"]}
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, doc))
    assert {:ok, ^doc} = Resolver.resolve_document(@did, opts)
    assert {:ok, ^doc} = Resolver.resolve_document(@did, opts)
    Req.Test.expect(__MODULE__, &Req.Test.json(&1, %{"id" => "wrong"}))

    assert {:error, :invalid_did_document} =
             Resolver.resolve_document(@did, Keyword.put(opts, :force_refresh, true))

    Req.Test.expect(__MODULE__, &Req.Test.json(&1, doc))
    assert {:ok, ^doc} = Resolver.resolve_document(@did, opts)

    for _ <- 1..2 do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, doc))
      assert {:ok, ^doc} = Resolver.resolve_document(@did, Keyword.delete(opts, :cache))
    end
  end
end
