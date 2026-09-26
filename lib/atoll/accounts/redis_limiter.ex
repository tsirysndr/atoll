defmodule Atoll.Accounts.RedisLimiter do
  @moduledoc "Atomic Redis five-minute budgets, capped at 10,000 buckets per namespace."
  @script """
  local time = redis.call('TIME')
  local now = tonumber(time[1]) * 1000 + math.floor(tonumber(time[2]) / 1000)
  local digest = ARGV[1]
  local limit = tonumber(ARGV[2])
  local expires = tonumber(redis.call('ZSCORE', KEYS[2], digest))
  if expires and expires > now then
    local count = tonumber(redis.call('HGET', KEYS[1], digest))
    if not count then return redis.error_reply('inconsistent limiter state') end
    if count >= limit then return math.max(1, math.ceil((expires - now) / 1000)) end
    redis.call('HINCRBY', KEYS[1], digest, 1)
  else
    local expired = redis.call('ZRANGEBYSCORE', KEYS[2], '-inf', now, 'LIMIT', 0, 1000)
    for _, member in ipairs(expired) do
      redis.call('HDEL', KEYS[1], member)
      redis.call('ZREM', KEYS[2], member)
    end
    if expires then
      redis.call('HDEL', KEYS[1], digest)
      redis.call('ZREM', KEYS[2], digest)
    end
    if redis.call('ZCARD', KEYS[2]) >= 10000 then return 300 end
    redis.call('HSET', KEYS[1], digest, 1)
    redis.call('ZADD', KEYS[2], now + 300000, digest)
  end
  redis.call('PEXPIRE', KEYS[1], 300000)
  redis.call('PEXPIRE', KEYS[2], 300000)
  return 0
  """

  def check(key, limit, opts \\ []) when is_integer(limit) and limit in 1..100_000 do
    config = Application.get_env(:atoll, :redis, [])
    namespace = Keyword.get(opts, :namespace, Keyword.get(config, :namespace, "atoll"))
    prefix = "{" <> namespace <> ":rate}:"

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(key, minor_version: 2))
      |> Base.encode16(case: :lower)

    connection = Keyword.get(opts, :connection, Atoll.Redis)

    case Redix.command(
           connection,
           [
             "EVAL",
             @script,
             "2",
             prefix <> "counts",
             prefix <> "expires",
             digest,
             Integer.to_string(limit)
           ],
           timeout: 2000
         ) do
      {:ok, 0} -> :ok
      {:ok, seconds} when is_integer(seconds) and seconds in 1..300 -> {:error, seconds}
      _ -> {:error, 1}
    end
  catch
    :exit, _ -> {:error, 1}
  end
end
