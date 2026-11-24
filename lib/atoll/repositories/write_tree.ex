defmodule Atoll.Repositories.WriteTree do
  @moduledoc "Batched canonical tree construction without rereading generated nodes over SQL."
  import Ecto.Query
  alias Atoll.{MST, Repo}
  alias Atoll.Storage.Block

  # Keep pending encoded bytes bounded independently of the builder's ancestor
  # budget. Only CIDs survive a flush; the caller consumes them before cleanup.
  def with_tree(records, callback) do
    pending = :ets.new(__MODULE__, [:set, :private])
    membership = :ets.new(__MODULE__, [:set, :private])
    :ets.insert(pending, {:bytes, 0})

    try do
      writer = fn cid, bytes ->
        :ets.insert(membership, {cid})
        :ets.insert(pending, {cid, bytes})
        size = :ets.update_counter(pending, :bytes, byte_size(bytes))
        if size >= 1_048_576 or :ets.info(pending, :size) >= 129, do: flush(pending)
        :ok
      end

      case MST.Builder.build(records, writer) do
        {:ok, root} ->
          flush(pending)

          cids =
            Stream.unfold(:ets.first(membership), fn
              :"$end_of_table" -> nil
              cid -> {cid, :ets.next(membership, cid)}
            end)

          callback.(root, cids)

        {:error, _} ->
          Repo.rollback(:invalid_repository)
      end
    after
      :ets.delete(pending)
      :ets.delete(membership)
    end
  end

  defp flush(table) do
    now = DateTime.utc_now()

    rows =
      for {cid, bytes} <- :ets.tab2list(table),
          is_binary(cid),
          do: %{cid: cid, data: bytes, inserted_at: now}

    if rows != [] do
      # A conflicting CID must still contain the expected bytes. Check existing
      # nodes in one batch, preserving corruption detection without one query
      # per emitted node (or another traversal of the complete tree).
      expected = Map.new(rows, &{&1.cid, &1.data})
      cids = Map.keys(expected)

      for {cid, data} <- Repo.all(from b in Block, where: b.cid in ^cids, select: {b.cid, b.data}) do
        if Map.fetch!(expected, cid) != data, do: Repo.rollback(:invalid_repository)
      end

      Repo.insert_all(Block, rows, on_conflict: :nothing, conflict_target: [:cid])
      :ets.delete_all_objects(table)
      :ets.insert(table, {:bytes, 0})
    end

    :ok
  end
end
