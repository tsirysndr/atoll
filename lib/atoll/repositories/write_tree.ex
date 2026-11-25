defmodule Atoll.Repositories.WriteTree do
  @moduledoc "Batched canonical tree construction without rereading generated nodes over SQL."
  import Ecto.Query
  alias Atoll.{CBOR, CID, Commit, MST, Repo, Storage}
  alias Atoll.Repositories.Head
  alias Atoll.Storage.Block

  # Optimistic reads do not hold the global publication lock. The publisher
  # checks both the base commit and exact edits after acquiring the head lock.
  def plan(did, edits) do
    Repo.with_primary(fn ->
      base =
        Repo.one(
          from h in Head,
            join: b in Block,
            on: b.cid == h.head,
            where: h.did == ^did,
            select: {h, b.data}
        )

      with {head, bytes} <- base,
           :ok <- CID.verify(head.head, bytes),
           {:ok, commit} <- Commit.verify(bytes, did, head.curve, head.public_key),
           true <- commit["rev"] == head.rev,
           root = commit["data"].cid,
           {:ok, edit} <- MST.Editor.apply(root, edits, &Storage.get_block/1) do
        known = Map.merge(edit.fetched, edit.created)
        before = reachable(root, known, MapSet.new())
        after_edit = reachable(edit.root, known, MapSet.new())
        added = MapSet.difference(after_edit, before) |> MapSet.to_list()
        removed = MapSet.difference(before, after_edit) |> MapSet.to_list()

        %{
          head: head.head,
          edits: edits,
          root: edit.root,
          blocks: Map.take(known, added),
          removed: removed
        }
      else
        _ -> nil
      end
    end)
  end

  # Stop at opaque links. Only known nodes can have changed; walking from
  # both roots also excludes transient nodes produced midway through a batch.
  defp reachable(nil, _, seen), do: seen

  defp reachable(cid, known, seen) do
    case Map.fetch(known, cid) do
      :error ->
        seen

      {:ok, bytes} ->
        if MapSet.member?(seen, cid) do
          seen
        else
          {:ok, %{"l" => left, "e" => entries}} = CBOR.decode(bytes)
          links = [left | Enum.map(entries, & &1["t"])]

          Enum.reduce(links, MapSet.put(seen, cid), fn
            nil, acc -> acc
            link, acc -> reachable(link.cid, known, acc)
          end)
        end
    end
  end

  def persist!(blocks) do
    blocks
    |> Stream.chunk_every(128)
    |> Enum.each(fn chunk ->
      {cids, bytes} = Enum.unzip(chunk)
      # Check existing bytes and insert missing CIDs in a single round trip.
      result =
        Repo.query!(
          """
          WITH incoming AS MATERIALIZED (
            SELECT * FROM unnest($1::bytea[], $2::bytea[]) AS i(cid, data)
          ), stored AS (
            INSERT INTO blocks (cid, data, inserted_at)
            SELECT cid, data, CURRENT_TIMESTAMP AT TIME ZONE 'UTC' FROM incoming
            ON CONFLICT (cid) DO NOTHING
          )
          SELECT EXISTS (SELECT 1 FROM incoming i JOIN blocks b USING (cid) WHERE b.data <> i.data)
          """,
          [cids, bytes]
        )

      if result.rows != [[false]], do: Repo.rollback(:invalid_repository)
    end)
  end

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
      insert_rows!(rows)
      :ets.delete_all_objects(table)
      :ets.insert(table, {:bytes, 0})
    end

    :ok
  end

  defp insert_rows!(rows) do
    # A conflicting CID must still contain the expected bytes. Check existing
    # nodes in one batch, preserving corruption detection without one query
    # per emitted node (or another traversal of the complete tree).
    expected = Map.new(rows, &{&1.cid, &1.data})
    cids = Map.keys(expected)

    for {cid, data} <- Repo.all(from b in Block, where: b.cid in ^cids, select: {b.cid, b.data}) do
      if Map.fetch!(expected, cid) != data, do: Repo.rollback(:invalid_repository)
    end

    Repo.insert_all(Block, rows, on_conflict: :nothing, conflict_target: [:cid])
  end
end
