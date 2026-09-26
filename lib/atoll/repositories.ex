defmodule Atoll.Repositories do
  @moduledoc """
  Internal, transactional repository storage. Not an authorization boundary.

  Callers provide a signing key or use the encrypted key vault. Mutations
  lock the head, enforce optional compare-and-swap, and atomically persist
  records, MST blocks, commit, and revision. Trees rebuild on each mutation.
  Old blocks are retained until reference tracking and GC exist.

  Records use ATProto JSON values and must match their collection's `$type`.
  This checks the data model, not record Lexicons. Account authorization and blob
  ownership must be added before exposing writes over HTTP.
  """
  import Ecto.Query
  alias Atoll.{CAR, CBOR, CID, Commit, DataModel, MST, Repo, SigningKey, Storage, Syntax, TID}
  alias Atoll.Repositories.{Head, Record, Snapshot}

  @doc "Creates a repository and encrypted signing key atomically. Requires the key vault master key."
  def create_managed(did, curve \\ :k256) when curve in [:p256, :k256] do
    key = SigningKey.generate(curve)

    Repo.transaction(fn ->
      with {:ok, head} <- create(did, key),
           {:ok, :stored} <- Atoll.KeyVault.store(did, key) do
        head
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Internal write API using the persisted signing key. Callers must authorize the account."
  def apply_managed_writes(did, operations, opts \\ []) do
    with {:ok, key} <- Atoll.KeyVault.fetch(did) do
      apply_writes(did, operations, key, opts)
    end
  end

  @doc """
  Replaces an existing repository with a verified complete CAR snapshot.

  Uses the repository's pinned public key and requires the caller's expected
  head CID. Revisions must advance, except an identical head is an idempotent
  retry. This internal API neither authorizes an account nor rotates its key.
  """
  def import_archive(did, archive, expected_head)
      when is_binary(did) and is_binary(expected_head) do
    with {:ok, prior} <- get_head(did),
         {:ok, snapshot} <- Snapshot.decode(archive, did, prior.curve, prior.public_key) do
      Repo.transaction(fn ->
        head = locked_head!(did, "FOR UPDATE")

        if head.head != expected_head or head.public_key != prior.public_key or
             head.curve != prior.curve,
           do: Repo.rollback(:invalid_swap)

        cond do
          snapshot.head == head.head ->
            head

          snapshot.rev <= head.rev ->
            Repo.rollback(:stale_revision)

          true ->
            Enum.each(snapshot.blocks, fn {cid, bytes} -> :ok = Storage.put_block(cid, bytes) end)
            Repo.delete_all(from r in Record, where: r.did == ^did)

            snapshot.records
            |> Enum.map(fn {path, cid} -> %{did: did, path: path, cid: cid} end)
            |> Enum.chunk_every(1000)
            |> Enum.each(&Repo.insert_all(Record, &1))

            head
            |> Ecto.Changeset.change(head: snapshot.head, rev: snapshot.rev)
            |> Repo.update!()
        end
      end)
    end
  end

  def import_archive(_, _, _), do: {:error, :invalid_snapshot}

  def create(did, %SigningKey{} = key) do
    with true <- Syntax.did?(did),
         {:ok, derived} <- SigningKey.from_private(key.curve, key.private),
         true <- derived.public == key.public do
      Repo.transaction(fn ->
        {:ok, tree} = MST.new()
        {:ok, rev} = TID.next()
        commit = persist_commit!(did, tree, rev, key)
        head = %{did: did, head: commit.cid, rev: rev, public_key: key.public, curve: key.curve}

        case Repo.insert_all(Head, [head], on_conflict: :nothing, conflict_target: [:did]) do
          {1, _} -> Repo.get!(Head, did)
          {0, _} -> Repo.rollback(:already_exists)
        end
      end)
    else
      _ -> {:error, :invalid_repository}
    end
  end

  def create(_, _), do: {:error, :invalid_repository}

  @doc "Applies up to 200 unique-path operations: {:create | :put, path, JSON map} or {:delete, path}."
  def apply_writes(did, operations, key, opts \\ []) do
    with {:ok, prepared} <- prepare(operations) do
      Repo.transaction(fn ->
        head = locked_head!(did, "FOR UPDATE")
        expected = Keyword.get(opts, :swap_commit, :any)
        if expected != :any and expected != head.head, do: Repo.rollback(:invalid_swap)
        unless matching_key?(key, head), do: Repo.rollback(:invalid_key)
        updated = Enum.reduce(prepared, record_map(did), &apply_operation!/2)
        {:ok, tree} = MST.new(updated)
        {:ok, rev} = TID.next(head.rev)
        commit = persist_commit!(did, tree, rev, key)
        Enum.each(prepared, &persist_record!(did, &1))
        head |> Ecto.Changeset.change(head: commit.cid, rev: rev) |> Repo.update!()
      end)
    end
  end

  def get_head(did) when is_binary(did) do
    case Repo.get(Head, did) do
      nil -> {:error, :not_found}
      head -> {:ok, head}
    end
  end

  @doc "Lists collections that currently contain at least one record."
  def collections(did) do
    with {:ok, _} <- get_head(did) do
      names =
        Repo.all(
          from r in Record,
            where: r.did == ^did,
            select: fragment("split_part(?, '/', 1)", r.path),
            distinct: true
        )

      {:ok, Enum.sort(names)}
    end
  end

  @doc "Lists hosted repository heads in bytewise DID order. Cursor is the last returned DID."
  def list_heads(limit, cursor \\ nil) when limit in 1..1000 do
    query =
      from h in Head, order_by: [asc: fragment("? COLLATE \"C\"", h.did)], limit: ^(limit + 1)

    query =
      if is_nil(cursor),
        do: query,
        else: from(h in query, where: fragment("? COLLATE \"C\" > ?", h.did, ^cursor))

    rows = Repo.all(query)
    page = Enum.take(rows, limit)

    result = %{
      repos:
        Enum.map(page, &%{did: &1.did, head: CID.to_base32(&1.head), rev: &1.rev, active: true})
    }

    if length(rows) > limit, do: Map.put(result, :cursor, List.last(page).did), else: result
  end

  def get_record(did, path) when is_binary(did) and is_binary(path) do
    case Repo.get_by(Record, did: did, path: path) do
      nil ->
        {:error, :not_found}

      record ->
        with {:ok, value} <- Storage.get_node(record.cid),
             {:ok, json} <- DataModel.to_json(value) do
          {:ok, %{uri: "at://" <> did <> "/" <> path, cid: record.cid, value: json}}
        end
    end
  end

  @doc "Lists current records in bytewise key order. Options are validated by the HTTP boundary."
  def list_records(did, collection, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    reverse = Keyword.get(opts, :reverse, false)
    cursor = Keyword.get(opts, :cursor)
    prefix = collection <> "/"
    upper = collection <> "0"

    with {:ok, _} <- get_head(did) do
      query =
        from r in Record,
          join: b in Atoll.Storage.Block,
          on: b.cid == r.cid,
          where: r.did == ^did,
          where:
            fragment(
              "? COLLATE \"C\" >= ? AND ? COLLATE \"C\" < ?",
              r.path,
              ^prefix,
              r.path,
              ^upper
            ),
          select: {r.path, r.cid, b.data},
          limit: ^(limit + 1)

      query =
        if reverse,
          do: from(r in query, order_by: [asc: fragment("? COLLATE \"C\"", r.path)]),
          else: from(r in query, order_by: [desc: fragment("? COLLATE \"C\"", r.path)])

      query =
        case {cursor, reverse} do
          {nil, _} ->
            query

          {key, true} ->
            from r in query, where: fragment("? COLLATE \"C\" > ?", r.path, ^(prefix <> key))

          {key, false} ->
            from r in query, where: fragment("? COLLATE \"C\" < ?", r.path, ^(prefix <> key))
        end

      rows = Repo.all(query)
      page = Enum.take(rows, limit)

      Enum.reduce_while(page, {:ok, []}, fn {path, cid, bytes}, {:ok, records} ->
        with :ok <- CID.verify(cid, bytes),
             {:ok, value} <- CBOR.decode(bytes),
             {:ok, json} <- DataModel.to_json(value) do
          {:cont, {:ok, [%{uri: "at://" <> did <> "/" <> path, cid: cid, value: json} | records]}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, records} ->
          result = %{records: Enum.reverse(records)}

          result =
            if length(rows) > limit do
              {path, _, _} = List.last(page)
              Map.put(result, :cursor, String.replace_prefix(path, prefix, ""))
            else
              result
            end

          {:ok, result}

        error ->
          error
      end
    end
  end

  @doc "Exports a consistent snapshot, holding a shared head lock until the CAR is assembled."
  def export(did) do
    Repo.transaction(fn ->
      {head, tree, commit} = snapshot!(did)

      blocks =
        Enum.reduce(Map.values(tree.records), tree.blocks, fn cid, acc ->
          Map.put(acc, cid, block!(cid))
        end)

      archive!([head.head], Map.put(blocks, head.head, commit))
    end)
  end

  @doc "Exports a compact existence or absence proof anchored to the current signed commit."
  def export_record(did, path) do
    Repo.transaction(fn ->
      {head, tree, commit} = snapshot!(did)

      case MST.proof(tree, path) do
        {:ok, proof} ->
          blocks = Map.put(proof.blocks, head.head, commit)
          blocks = if proof.cid, do: Map.put(blocks, proof.cid, block!(proof.cid)), else: blocks
          archive!([head.head], blocks)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc "Exports requested blocks reachable from the current repository, excluding retained history."
  def export_blocks(did, cids) when is_list(cids) and length(cids) in 1..100 do
    Repo.transaction(fn ->
      {head, tree, commit} = snapshot!(did)
      available = MapSet.new([head.head | Map.keys(tree.blocks) ++ Map.values(tree.records)])
      unless Enum.all?(cids, &MapSet.member?(available, &1)), do: Repo.rollback(:block_not_found)

      blocks =
        Enum.reduce(Enum.uniq(cids), %{}, fn cid, acc ->
          bytes =
            cond do
              cid == head.head -> commit
              Map.has_key?(tree.blocks, cid) -> Map.fetch!(tree.blocks, cid)
              true -> block!(cid)
            end

          Map.put(acc, cid, bytes)
        end)

      archive!([], blocks)
    end)
  end

  def export_blocks(_, _), do: {:error, :invalid_request}

  defp snapshot!(did) do
    head = locked_head!(did, "FOR SHARE")
    bytes = block!(head.head)

    with {:ok, tree} <- MST.new(record_map(did)),
         {:ok, commit} <- Commit.verify(bytes, did, head.curve, head.public_key),
         true <- commit["data"].cid == tree.root and commit["rev"] == head.rev do
      {head, tree, bytes}
    else
      _ -> Repo.rollback(:invalid_repository)
    end
  end

  defp block!(cid) do
    with {:ok, bytes} <- Storage.get_block(cid), :ok <- CID.verify(cid, bytes) do
      bytes
    else
      _ -> Repo.rollback(:invalid_repository)
    end
  end

  defp archive!(roots, blocks) do
    case CAR.encode(roots, blocks) do
      {:ok, archive} -> archive
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp locked_head!(did, lock) do
    query = from h in Head, where: h.did == ^did

    query =
      case lock do
        "FOR UPDATE" -> from h in query, lock: "FOR UPDATE"
        "FOR SHARE" -> from h in query, lock: "FOR SHARE"
      end

    Repo.one(query) || Repo.rollback(:not_found)
  end

  defp record_map(did),
    do: Repo.all(from r in Record, where: r.did == ^did, select: {r.path, r.cid}) |> Map.new()

  defp matching_key?(%SigningKey{curve: curve, public: public, private: private}, head) do
    curve == head.curve and public == head.public_key and
      case SigningKey.from_private(curve, private) do
        {:ok, key} -> key.public == public
        _ -> false
      end
  end

  defp matching_key?(_, _), do: false

  defp prepare(operations) when is_list(operations) and length(operations) in 1..200 do
    Enum.reduce_while(operations, {:ok, [], MapSet.new()}, fn op, {:ok, acc, paths} ->
      case prepare_operation(op) do
        {:ok, {_, path, _, _} = prepared} ->
          if MapSet.member?(paths, path),
            do: {:halt, {:error, :duplicate_path}},
            else: {:cont, {:ok, [prepared | acc], MapSet.put(paths, path)}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared, _} -> {:ok, Enum.reverse(prepared)}
      error -> error
    end
  end

  defp prepare(_), do: {:error, :invalid_writes}

  defp prepare_operation({:delete, path}) do
    if Syntax.repo_path?(path),
      do: {:ok, {:delete, path, nil, nil}},
      else: {:error, :invalid_record}
  end

  defp prepare_operation({action, path, %{"$type" => type} = json})
       when action in [:create, :put] do
    with true <- Syntax.repo_path?(path),
         [^type, _] <- String.split(path, "/"),
         {:ok, value} <- DataModel.from_json(json),
         bytes = CBOR.encode!(value),
         true <- byte_size(bytes) <= 1_000_000 do
      {:ok, {action, path, CID.create(bytes, :dag_cbor), bytes}}
    else
      _ -> {:error, :invalid_record}
    end
  end

  defp prepare_operation(_), do: {:error, :invalid_record}

  defp apply_operation!({:create, path, cid, _}, records) do
    if Map.has_key?(records, path), do: Repo.rollback(:record_exists)
    Map.put(records, path, cid)
  end

  defp apply_operation!({:put, path, cid, _}, records), do: Map.put(records, path, cid)
  defp apply_operation!({:delete, path, _, _}, records), do: Map.delete(records, path)

  defp persist_record!(did, {:delete, path, _, _}),
    do: Repo.delete_all(from r in Record, where: r.did == ^did and r.path == ^path)

  defp persist_record!(did, {_, path, cid, bytes}) do
    :ok = Storage.put_block(cid, bytes)

    Repo.insert!(%Record{did: did, path: path, cid: cid},
      on_conflict: {:replace, [:cid]},
      conflict_target: [:did, :path]
    )
  end

  defp persist_commit!(did, tree, rev, key) do
    Enum.each(tree.blocks, fn {cid, bytes} -> :ok = Storage.put_block(cid, bytes) end)
    {:ok, commit} = Commit.create(did, tree.root, rev, key)
    :ok = Storage.put_block(commit.cid, commit.bytes)
    commit
  end
end
