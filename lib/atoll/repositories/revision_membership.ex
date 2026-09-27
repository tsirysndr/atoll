defmodule Atoll.Repositories.RevisionMembership do
  @moduledoc "Stages verified revision CIDs in the database without accumulating a membership list."
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

  defp query!(sql, params), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
end
