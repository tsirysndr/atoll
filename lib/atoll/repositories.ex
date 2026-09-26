defmodule Atoll.Repositories do
  @moduledoc """
  Internal, transactional repository storage. Not an authorization boundary.

  Callers provide the signing key; private keys are never stored here. Mutations
  lock the head, enforce optional compare-and-swap, and atomically persist
  records, MST blocks, commit, and revision. Trees rebuild on each mutation.
  Old blocks are retained until reference tracking and GC exist.

  Records use ATProto JSON values and must match their collection's `$type`.
  This checks the data model, not record Lexicons. Account authorization and blob
  ownership must be added before exposing writes over HTTP.
  """
  import Ecto.Query
  alias Atoll.{CAR, CBOR, CID, Commit, DataModel, MST, Repo, SigningKey, Storage, Syntax, TID}
  alias Atoll.Repositories.{Head, Record}

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

  @doc "Exports a consistent snapshot, holding a shared head lock until the CAR is assembled."
  def export(did) do
    Repo.transaction(fn ->
      head = locked_head!(did, "FOR SHARE")
      records = record_map(did)
      {:ok, tree} = MST.new(records)

      blocks =
        Enum.reduce([head.head | Map.values(records)], tree.blocks, fn cid, acc ->
          case Storage.get_block(cid) do
            {:ok, data} -> Map.put(acc, cid, data)
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case CAR.encode([head.head], blocks) do
        {:ok, archive} -> archive
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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
