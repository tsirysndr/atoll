defmodule Atoll.RedisLimiterTest do
  use ExUnit.Case, async: true
  alias Atoll.Accounts.{RedisLimiter, SessionLimiter}

  test "memory remains the default and Redis configuration is optional" do
    assert SessionLimiter.backend_from_env!(nil) == :memory
    assert SessionLimiter.backend_from_env!("redis") == :redis
    assert Atoll.Redis.config!(%{}, :memory) == []

    assert Atoll.Redis.config!(
             %{"ATOLL_REDIS_URL" => "rediss://user:secret@redis.example.com:6380/2"},
             :redis
           ) ==
             [url: "rediss://user:secret@redis.example.com:6380/2", namespace: "atoll"]

    for env <- [
          %{},
          %{"ATOLL_REDIS_URL" => "http://secret.example.com"},
          %{"ATOLL_REDIS_URL" => "redis://localhost", "ATOLL_REDIS_NAMESPACE" => "{invalid}"}
        ] do
      error = assert_raise RuntimeError, fn -> Atoll.Redis.config!(env, :redis) end
      refute error.message =~ "secret"
    end
  end

  test "missing Redis process fails closed" do
    assert {:error, 1} =
             RedisLimiter.check(:example, 2, connection: :missing_redis_test_connection)
  end

  @tag :redis
  test "real Redis shares atomic budgets, expires old entries, and separates namespaces" do
    url = System.fetch_env!("ATOLL_TEST_REDIS_URL")
    a = start_supervised!({Redix, {url, [sync_connect: true]}})

    b =
      start_supervised!(Supervisor.child_spec({Redix, {url, [sync_connect: true]}}, id: :second))

    namespace = "test_#{System.unique_integer([:positive])}"
    prefix = "{#{namespace}:rate}:"

    on_exit(fn ->
      {:ok, cleanup} = Redix.start_link(url, sync_connect: true)
      Redix.command!(cleanup, ["DEL", prefix <> "counts", prefix <> "expires"])
      Redix.stop(cleanup)
    end)

    results =
      1..30
      |> Task.async_stream(fn n ->
        RedisLimiter.check(:shared, 10,
          connection: if(rem(n, 2) == 0, do: a, else: b),
          namespace: namespace
        )
      end)
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.count(results, &(&1 == :ok)) == 10
    assert Enum.count(results, &match?({:error, seconds} when seconds > 0, &1)) == 20
    assert Redix.command!(a, ["HLEN", prefix <> "counts"]) == 1
    assert Redix.command!(a, ["PTTL", prefix <> "counts"]) in 1..300_000
    [digest] = Redix.command!(a, ["HKEYS", prefix <> "counts"])
    Redix.command!(a, ["ZADD", prefix <> "expires", "0", digest])
    assert :ok = RedisLimiter.check(:shared, 10, connection: b, namespace: namespace)
    assert :ok = RedisLimiter.check(:separate, 1, connection: a, namespace: namespace)
    assert {:error, _} = RedisLimiter.check(:separate, 1, connection: b, namespace: namespace)

    Redix.command!(a, ["DEL", prefix <> "counts", prefix <> "expires"])

    seed = """
    local time = redis.call('TIME')
    local expiry = tonumber(time[1]) * 1000 + 300000
    for i = 1, 10000 do
      redis.call('HSET', KEYS[1], tostring(i), 1)
      redis.call('ZADD', KEYS[2], expiry, tostring(i))
    end
    return 1
    """

    Redix.command!(a, ["EVAL", seed, "2", prefix <> "counts", prefix <> "expires"])
    assert {:error, 300} = RedisLimiter.check(:new, 10, connection: a, namespace: namespace)
    assert Redix.command!(a, ["HLEN", prefix <> "counts"]) == 10_000
    Redix.command!(a, ["ZADD", prefix <> "expires", "0", "1"])
    assert :ok = RedisLimiter.check(:new, 10, connection: a, namespace: namespace)
    assert Redix.command!(a, ["HLEN", prefix <> "counts"]) == 10_000
  end
end
