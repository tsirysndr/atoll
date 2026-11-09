defmodule Atoll.OAuth.Admission do
  @moduledoc false
  import Ecto.Query
  require Atoll.Database
  alias Atoll.{Database, Repo}
  alias Atoll.OAuth.{ClientAssertionUse, ProofUse, PKCEUse, PushedRequest}

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

  def prune_and_status!(schema, now, digest) do
    transaction!()
    table = marker_table!(schema)

    if Database.postgres?() do
      # Data-modifying CTEs share a snapshot. Subtract RETURNING rows from
      # counts and replay checks instead of expecting SELECT to see DELETE.
      # The advisory lock must already have been acquired by an earlier
      # statement, so this snapshot includes any preceding admission commit.
      %{rows: [[replayed, count]]} =
        Repo.query!(
          """
          WITH pruned AS (
            DELETE FROM #{table}
            WHERE digest IN (
              SELECT digest FROM #{table} WHERE expires_at <= $1
              ORDER BY expires_at, digest LIMIT 1000
            )
            RETURNING digest
          )
          SELECT EXISTS(SELECT 1 FROM #{table} WHERE digest = $2)
                   AND NOT EXISTS(SELECT 1 FROM pruned WHERE digest = $2),
                 (SELECT count(*) FROM #{table}) - (SELECT count(*) FROM pruned)
          """,
          [now, digest],
          log: false
        )

      %{replayed: replayed, count: count}
    else
      prune!(schema, now)

      %{
        replayed: not is_nil(Repo.get(schema, digest, log: false)),
        count: Repo.aggregate(schema, :count)
      }
    end
  end

  def request_status!(now, challenge_digest) do
    transaction!()

    if Database.postgres?() do
      %{rows: [[replayed, requests, challenges]]} =
        Repo.query!(
          """
          WITH pruned_requests AS (
            DELETE FROM oauth_pushed_requests WHERE digest IN (
              SELECT digest FROM oauth_pushed_requests WHERE expires_at <= $1
              ORDER BY expires_at, digest LIMIT 1000
            ) RETURNING digest
          ), pruned_challenges AS (
            DELETE FROM oauth_pkce_uses WHERE digest IN (
              SELECT digest FROM oauth_pkce_uses WHERE expires_at <= $1
              ORDER BY expires_at, digest LIMIT 1000
            ) RETURNING digest
          )
          SELECT EXISTS(SELECT 1 FROM oauth_pkce_uses WHERE digest = $2)
                   AND NOT EXISTS(SELECT 1 FROM pruned_challenges WHERE digest = $2),
                 (SELECT count(*) FROM oauth_pushed_requests)
                   - (SELECT count(*) FROM pruned_requests),
                 (SELECT count(*) FROM oauth_pkce_uses)
                   - (SELECT count(*) FROM pruned_challenges)
          """,
          [now, challenge_digest],
          log: false
        )

      %{replayed: replayed, requests: requests, challenges: challenges}
    else
      prune!(PushedRequest, now)
      prune!(PKCEUse, now)

      %{
        replayed: not is_nil(Repo.get(PKCEUse, challenge_digest, log: false)),
        requests: Repo.aggregate(PushedRequest, :count),
        challenges: Repo.aggregate(PKCEUse, :count)
      }
    end
  end

  def insert_request!(%PKCEUse{} = challenge, %PushedRequest{} = request) do
    transaction!()

    if Database.postgres?() do
      expected = request.digest

      %{rows: [[^expected]]} =
        Repo.query!(
          """
          WITH inserted_challenge AS (
            INSERT INTO oauth_pkce_uses (digest, expires_at)
            VALUES ($1, $2) RETURNING digest
          )
          INSERT INTO oauth_pushed_requests
            (digest, issuer, client_id, parameters, permission_sets, dpop_jkt, client_binding, expires_at)
          SELECT $3, $4, $5, $6, $7, $8, $9, $10 FROM inserted_challenge
          RETURNING digest
          """,
          [
            challenge.digest,
            challenge.expires_at,
            request.digest,
            request.issuer,
            request.client_id,
            request.parameters,
            request.permission_sets,
            request.dpop_jkt,
            request.client_binding,
            request.expires_at
          ],
          log: false
        )
    else
      Repo.insert!(challenge, log: false)
      Repo.insert!(request, log: false)
    end

    :ok
  end

  defp marker_table!(ClientAssertionUse), do: "oauth_client_assertion_uses"
  defp marker_table!(ProofUse), do: "oauth_dpop_uses"
  defp marker_table!(PKCEUse), do: "oauth_pkce_uses"

  defp transaction! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "OAuth admission requires a transaction")
  end
end
