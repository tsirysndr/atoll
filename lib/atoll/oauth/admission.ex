defmodule Atoll.OAuth.Admission do
  @moduledoc false
  import Ecto.Query
  require Atoll.Database
  alias Atoll.{Database, Repo}

  # Keep transaction setup and bounded cleanup in single statements so
  # database round-trip latency does not multiply across OAuth admission.
  def start!(lock \\ nil) do
    transaction!()

    if Database.postgres?() do
      settings = """
      SELECT set_config('lock_timeout', '1000ms', true),
             set_config('statement_timeout', '5000ms', true)
      """

      {query, params} =
        if is_nil(lock) do
          {"""
           WITH limits AS MATERIALIZED (#{settings})
           SELECT floor(extract(epoch FROM clock_timestamp()))::bigint FROM limits
           """, []}
        else
          {"""
           WITH limits AS MATERIALIZED (#{settings}),
           locked AS MATERIALIZED (SELECT pg_advisory_xact_lock($1) FROM limits)
           SELECT floor(extract(epoch FROM clock_timestamp()))::bigint FROM locked
           """, [lock]}
        end

      %{rows: [[now]]} = Repo.query!(query, params, log: false)
      now
    else
      Database.now_seconds!()
    end
  end

  def lock_now!(lock) when is_integer(lock) do
    transaction!()

    if Database.postgres?() do
      # Read wall time after acquiring the lock, including any time spent
      # waiting for another request's replay-admission transaction.
      %{rows: [[now]]} =
        Repo.query!(
          """
          WITH locked AS MATERIALIZED (SELECT pg_advisory_xact_lock($1))
          SELECT floor(extract(epoch FROM clock_timestamp()))::bigint FROM locked
          """,
          [lock],
          log: false
        )

      now
    else
      Database.now_seconds!()
    end
  end

  def prune!(schema, now) do
    transaction!()

    expired =
      from(row in schema,
        where: row.expires_at <= ^now,
        order_by: [asc: row.expires_at, asc: row.digest],
        limit: 1000,
        select: row.digest
      )

    Repo.delete_all(from(row in schema, where: row.digest in subquery(expired)), log: false)
  end

  defp transaction! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "OAuth admission requires a transaction")
  end
end
