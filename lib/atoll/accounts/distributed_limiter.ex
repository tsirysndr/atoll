defmodule Atoll.Accounts.DistributedLimiter do
  @moduledoc "PostgreSQL-shared five-minute request budgets with bounded storage and fail-closed errors."
  alias Atoll.Repo
  @capacity 10_000
  @lock 4_182_026_002

  def check(key, limit) when is_integer(limit) and limit > 0 and limit <= 100_000 do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(key, minor_version: 2))

    case Repo.transaction(fn -> check!(digest, limit) end) do
      {:ok, result} -> result
      {:error, _} -> unavailable()
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> unavailable()
  catch
    :exit, _ -> unavailable()
  end

  defp check!(digest, limit) do
    Repo.query!("SET LOCAL lock_timeout = '1s'")
    Repo.query!("SET LOCAL statement_timeout = '2s'")
    # One cluster-wide lock makes quota admission and the global storage cap atomic.
    # It is distinct from repository sequencing and never acquires repository locks.
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock], log: false)
    %{rows: [[now]]} = Repo.query!("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")

    case Repo.query!(
           "SELECT count, expires_at FROM request_rate_buckets WHERE digest = $1",
           [digest],
           log: false
         ).rows do
      [[count, expiry]] when expiry > now and count >= limit ->
        {:error, max(1, expiry - now)}

      [[_count, expiry]] when expiry > now ->
        Repo.query!(
          "UPDATE request_rate_buckets SET count = count + 1 WHERE digest = $1",
          [digest],
          log: false
        )

        :ok

      [[_, _]] ->
        Repo.query!(
          "UPDATE request_rate_buckets SET count = 1, expires_at = $2 WHERE digest = $1",
          [digest, now + 300],
          log: false
        )

        :ok

      [] ->
        admit!(digest, now)
    end
  end

  defp admit!(digest, now) do
    # Reclaim at most one batch before admitting a new key. Idle storage stays bounded.
    Repo.query!(
      """
      DELETE FROM request_rate_buckets WHERE digest IN
        (SELECT digest FROM request_rate_buckets WHERE expires_at <= $1 ORDER BY expires_at, digest LIMIT 1000)
      """,
      [now],
      log: false
    )

    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM request_rate_buckets")

    if count < @capacity do
      Repo.query!(
        "INSERT INTO request_rate_buckets (digest, count, expires_at) VALUES ($1, 1, $2)",
        [digest, now + 300],
        log: false
      )

      :ok
    else
      {:error, 300}
    end
  end

  defp unavailable do
    :telemetry.execute([:atoll, :rate_limit, :unavailable], %{count: 1}, %{})
    {:error, 1}
  end
end
