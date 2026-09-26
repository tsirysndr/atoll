defmodule Atoll.Storage.Cleanup do
  @moduledoc "Bounded collection of old DAG-CBOR blocks not owned by any retained repository revision."
  import Ecto.Query
  alias Atoll.{Repo, Storage.Block}
  alias Atoll.Repositories.{BlockReference, Events, Head, Record, Revision}

  def prune(opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)
    grace = Keyword.get(opts, :grace_seconds, 86_400)

    cond do
      Repo.in_transaction?() ->
        {:error, :cleanup_requires_own_transaction}

      not is_integer(limit) or limit not in 1..1000 or not is_integer(grace) or
          grace not in 3600..31_536_000 ->
        {:error, :invalid_cleanup_options}

      true ->
        collect(limit, grace)
    end
  end

  defp collect(limit, grace) do
    cutoff = DateTime.add(DateTime.utc_now(), -grace, :second)

    Repo.transaction(
      fn ->
        Ecto.Adapters.SQL.query!(Repo, "SET LOCAL lock_timeout = '1s'", [])
        Ecto.Adapters.SQL.query!(Repo, "SET LOCAL statement_timeout = '5s'", [])

        # The same lock covers writes/imports/deletion so no new ownership can appear between selection and deletion.
        Events.lock!()

        history =
          from r in BlockReference,
            where: r.cid == parent_as(:block).cid,
            select: 1

        heads = from h in Head, where: h.head == parent_as(:block).cid, select: 1
        commits = from r in Revision, where: r.head == parent_as(:block).cid, select: 1
        records = from r in Record, where: r.cid == parent_as(:block).cid, select: 1

        candidates =
          from b in Block,
            as: :block,
            where: b.inserted_at < ^cutoff,
            where: fragment("substring(? from 1 for 4) = decode('01711220', 'hex')", b.cid),
            where:
              not exists(subquery(history)) and not exists(subquery(heads)) and
                not exists(subquery(commits)) and not exists(subquery(records)),
            order_by: [asc: b.inserted_at, asc: b.cid],
            limit: ^limit,
            lock: "FOR UPDATE SKIP LOCKED",
            select: b.cid

        cids = Repo.all(candidates)
        {count, _} = Repo.delete_all(from b in Block, where: b.cid in ^cids)
        count
      end,
      timeout: 10_000
    )
  rescue
    error in Postgrex.Error ->
      case error.postgres[:code] do
        :lock_not_available -> {:error, :cleanup_busy}
        :query_canceled -> {:error, :cleanup_timeout}
        _ -> reraise error, __STACKTRACE__
      end
  end
end
