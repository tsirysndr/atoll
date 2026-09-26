defmodule Atoll.Repositories.Compaction do
  @moduledoc "Operator revision compaction preserving current heads and retained replay dependencies."
  import Ecto.Query
  alias Atoll.{Repo, Syntax}
  alias Atoll.Repositories.{EventDependencies, EventDependency, Events, Head, Revision}

  def prune(did, limit \\ 100, retention_seconds \\ 604_800)

  def prune(did, limit, seconds)
      when is_integer(limit) and limit in 1..100 and is_integer(seconds) and
             seconds in 3600..31_536_000 do
    if Syntax.did?(did) do
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '1s'")
        Repo.query!("SET LOCAL statement_timeout = '5s'")
        Events.lock!()

        head =
          Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
            Repo.rollback(:not_found)

        index = EventDependencies.backfill!(did)

        if index.incomplete do
          Map.merge(index, %{pruned: 0})
        else
          %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp() AT TIME ZONE 'UTC'")
          cutoff = now |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(-seconds, :second)

          pins =
            from d in EventDependency,
              where: d.did == parent_as(:revision).did and d.head == parent_as(:revision).head,
              select: 1

          revisions =
            Repo.all(
              from r in Revision,
                as: :revision,
                where: r.did == ^did and r.rev != ^head.rev and r.head != ^head.head,
                where: r.inserted_at < ^cutoff and not exists(subquery(pins)),
                order_by: r.rev,
                limit: ^limit,
                select: r.rev
            )

          {count, _} =
            Repo.delete_all(from r in Revision, where: r.did == ^did and r.rev in ^revisions)

          Map.merge(index, %{pruned: count})
        end
      end)
    else
      {:error, :invalid_compaction_options}
    end
  rescue
    _ in [MatchError, CaseClauseError] ->
      {:error, :invalid_event_dependencies}

    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :compaction_busy},
        else: reraise(e, __STACKTRACE__)
  end

  def prune(_, _, _), do: {:error, :invalid_compaction_options}
end
