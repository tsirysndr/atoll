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
    _ in [Exqlite.Error, Postgrex.Error, DBConnection.ConnectionError] -> unavailable()
  catch
    :exit, _ -> unavailable()
  end

  defp check!(digest, limit) do
    Atoll.Database.limits!(1_000, 2_000)
    # One cluster-wide lock makes quota admission and the global storage cap atomic.
    # It is distinct from repository sequencing and never acquires repository locks.
    Atoll.Database.serialize_writes!(@lock)
    now = Atoll.Database.now_seconds!()

    case Repo.query!(
           "SELECT count, expires_at FROM request_rate_buckets WHERE digest = $1",
           [Atoll.Database.blob(digest)],
           log: false
         ).rows do
      [[count, expiry]] when expiry > now and count >= limit ->
        {:error, max(1, expiry - now)}

      [[_count, expiry]] when expiry > now ->
        Repo.query!(
          "UPDATE request_rate_buckets SET count = count + 1 WHERE digest = $1",
          [Atoll.Database.blob(digest)],
          log: false
        )

        :ok

      [[_, _]] ->
        Repo.query!(
          Atoll.Database.sql(
            "UPDATE request_rate_buckets SET count = 1, expires_at = $2 WHERE digest = $1",
            "UPDATE request_rate_buckets SET count = 1, expires_at = ?2 WHERE digest = ?1"
          ),
          [Atoll.Database.blob(digest), now + 300],
          log: false
        )

        :ok

      [] ->
        admit!(digest, now)
    end
  end

  defp admit!(digest, now) do
    # Evaluate the bounded candidate selection once, even with stale/empty table
    # statistics. An IN subquery can choose a repeated nested-loop semi join.
    # Reclaim at most one batch before admitting a new key. Idle storage stays bounded.
    Repo.query!(
      Atoll.Database.sql(
        """
        DELETE FROM request_rate_buckets WHERE digest = ANY(ARRAY(
          SELECT digest FROM request_rate_buckets WHERE expires_at <= $1 ORDER BY expires_at, digest LIMIT 1000
        ))
        """,
        """
        DELETE FROM request_rate_buckets WHERE digest IN (
          SELECT digest FROM request_rate_buckets WHERE expires_at <= $1 ORDER BY expires_at, digest LIMIT 1000
        )
        """
      ),
      [now],
      log: false
    )

    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM request_rate_buckets")

    if count < @capacity do
      Repo.query!(
        "INSERT INTO request_rate_buckets (digest, count, expires_at) VALUES ($1, 1, $2)",
        [Atoll.Database.blob(digest), now + 300],
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
