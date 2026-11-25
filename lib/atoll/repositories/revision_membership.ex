defmodule Atoll.Repositories.RevisionMembership do
  @moduledoc "Stages verified revision CIDs in the database without accumulating a membership list."
  require Atoll.Database
  import Ecto.Query
  alias Atoll.Repo

  @doc "Internal API: callers must hold the repository write lock and supply verified reachable CIDs."
  def insert!(head, cids) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "revision staging requires a transaction")

    # Identifier consists exclusively of a fixed prefix and locally generated hex.
    table = "atoll_revision_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    query!(
      Atoll.Database.sql(
        "CREATE TEMP TABLE #{table} (cid bytea PRIMARY KEY) ON COMMIT DROP",
        "CREATE TEMP TABLE #{table} (cid BLOB PRIMARY KEY)"
      ),
      []
    )

    Stream.concat([head.head], cids)
    |> Stream.chunk_every(256)
    |> Enum.each(fn batch ->
      Repo.insert_all(table, Enum.map(batch, &%{cid: Atoll.Database.blob(&1)}),
        on_conflict: :nothing
      )
    end)

    query!(
      Atoll.Database.sql(
        """
        INSERT INTO repository_revisions
          (did, rev, head, signing_curve, signing_public_key, blocks, inserted_at)
        SELECT $1, $2, $3, $4, $5, ARRAY(SELECT cid FROM #{table} ORDER BY cid),
               CURRENT_TIMESTAMP AT TIME ZONE 'UTC'
        """,
        """
        INSERT INTO repository_revisions
          (did, rev, head, signing_curve, signing_public_key, blocks, inserted_at)
        SELECT ?1, ?2, ?3, ?4, ?5, (SELECT json_group_array(hex(cid)) FROM (SELECT cid FROM #{table} ORDER BY cid)),
               strftime('%Y-%m-%dT%H:%M:%f000', 'now')
        """
      ),
      [
        head.did,
        head.rev,
        Atoll.Database.blob(head.head),
        Atom.to_string(head.curve),
        Atoll.Database.blob(head.public_key)
      ]
    )

    query!("DROP TABLE #{table}", [])
    Atoll.Repositories.Quota.check!(head.did)
  end

  @doc "Persist a builder's verified nodes and the current indexed records in one statement."
  def insert_built!(head, nodes) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "revision staging requires a transaction")

    if Atoll.Database.postgres?() do
      query!(
        """
        INSERT INTO repository_revisions
          (did, rev, head, signing_curve, signing_public_key, blocks, inserted_at)
        SELECT $1, $2, $3, $4, $5,
          ARRAY(SELECT cid FROM (
            SELECT unnest($6::bytea[]) AS cid
            UNION SELECT cid FROM repository_records WHERE did = $1
            UNION SELECT $3::bytea
          ) AS membership ORDER BY cid),
          CURRENT_TIMESTAMP AT TIME ZONE 'UTC'
        """,
        [
          head.did,
          head.rev,
          head.head,
          Atom.to_string(head.curve),
          head.public_key,
          Enum.to_list(nodes)
        ]
      )

      Atoll.Repositories.Quota.check!(head.did)
    else
      records =
        from(r in Atoll.Repositories.Record, where: r.did == ^head.did, select: r.cid)
        |> Repo.stream(max_rows: 1024)

      insert!(head, Stream.concat(nodes, records))
    end
  end

  def insert_edited!(head, base, removed, added, previous_records, grew?) do
    # A record CID may occur at multiple paths. Keep it if any post-write
    # record still references it. Typed records cannot be MST nodes or commits.
    result =
      query!(
        """
        INSERT INTO repository_revisions
          (did, rev, head, signing_curve, signing_public_key, blocks, inserted_at)
        SELECT $1, $2, $3, $4, $5, membership.blocks, CURRENT_TIMESTAMP AT TIME ZONE 'UTC'
        FROM repository_revisions r
        CROSS JOIN LATERAL (SELECT ARRAY(
          SELECT cid FROM (
            SELECT unnest(r.blocks) AS cid
            EXCEPT SELECT unnest($7::bytea[])
            UNION SELECT unnest($8::bytea[])
            UNION SELECT cid FROM repository_records WHERE did = $1 AND cid = ANY($9::bytea[])
          ) AS members ORDER BY cid
        ) AS blocks) AS membership
        WHERE r.did = $1 AND r.rev = $6 AND r.head = $10
          AND (NOT $11::boolean OR NOT EXISTS
            (SELECT 1 FROM repository_records WHERE did = $1 OFFSET 1000000))
          AND CASE WHEN cardinality(membership.blocks) > 100001 THEN
            cardinality(membership.blocks) - 1 -
              (SELECT count(DISTINCT cid) FROM repository_records WHERE did = $1) <= 100000
            ELSE true END
        """,
        [
          head.did,
          head.rev,
          head.head,
          Atom.to_string(head.curve),
          head.public_key,
          base.rev,
          [base.head | removed ++ previous_records],
          [head.head | added],
          previous_records,
          base.head,
          grew?
        ]
      )

    if result.num_rows != 1, do: Repo.rollback(:invalid_repository)
    Atoll.Repositories.Quota.check!(head.did)
  end

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
