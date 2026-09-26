defmodule Atoll.Repositories do
  @moduledoc """
  Internal, transactional repository storage. Not an authorization boundary.

  Callers provide a signing key or use the encrypted key vault. Mutations
  lock the head, enforce optional compare-and-swap, and atomically persist
  records, MST blocks, commit, and revision. Trees rebuild on each mutation.
  Retained revisions own their blocks; unowned blocks can be garbage-collected.

  Records use ATProto JSON values and must match their collection's `$type`.
  This checks the data model, not record Lexicons. Public write handlers separately
  enforce account authorization, and mutations check blob ownership and quotas.
  """
  import Ecto.Query
  alias Atoll.{CAR, CBOR, CID, Commit, DataModel, MST, Repo, SigningKey, Storage, Syntax, TID}
  alias Atoll.Repositories.{Events, Head, Record, Revision, Snapshot, Takedown, Takedowns}

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
      import_snapshot(did, prior, snapshot, expected_head, nil)
    end
  end

  def import_archive(_, _, _), do: {:error, :invalid_snapshot}

  @doc "Imports a complete snapshot for the token owner, rechecking authorization and the captured head under lock."
  def import_authenticated(token, archive, expected_head) do
    with {:ok, %{did: did} = prior} <- Atoll.Accounts.Sessions.authenticate_management(token),
         {:ok, snapshot} <- authenticated_snapshot(prior, archive) do
      import_snapshot(did, prior, snapshot, expected_head, token)
    end
  end

  defp import_snapshot(did, prior, snapshot, expected_head, token) do
    Repo.transaction(fn ->
      Events.lock!()
      head = locked_head!(did, "FOR UPDATE", is_nil(token))

      if token do
        case Atoll.Accounts.Sessions.authenticate_management(token) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      if head.head != expected_head or head.public_key != prior.public_key or
           head.curve != prior.curve,
         do: Repo.rollback(:invalid_swap)

      snapshot = localize_import!(head, snapshot)

      cond do
        snapshot.head == head.head ->
          head

        snapshot.rev <= head.rev ->
          Repo.rollback(:stale_revision)

        true ->
          Atoll.Blobs.References.import!(did, snapshot.records, snapshot.blocks, snapshot.rev)
          Enum.each(snapshot.blocks, fn {cid, bytes} -> :ok = Storage.put_block(cid, bytes) end)
          Repo.delete_all(from r in Record, where: r.did == ^did)

          snapshot.records
          |> Enum.map(fn {path, cid} -> %{did: did, path: path, cid: cid} end)
          |> Enum.chunk_every(1000)
          |> Enum.each(&Repo.insert_all(Record, &1))

          updated =
            head
            |> Ecto.Changeset.change(head: snapshot.head, rev: snapshot.rev)
            |> Repo.update!()

          remember_revision!(updated, Map.keys(snapshot.blocks))
          Events.append!(:sync, updated, event_head(updated, head))
          updated
      end
    end)
  end

  defp authenticated_snapshot(head, archive) do
    case Snapshot.decode(archive, head.did, head.curve, head.public_key) do
      {:error, :invalid_snapshot} = error when head.status == :deactivated ->
        case Repo.get(Atoll.Accounts.Profile, head.did) do
          %{import_curve: curve, import_public_key: public} when not is_nil(public) ->
            with {:ok, snapshot} <- Snapshot.decode(archive, head.did, curve, public),
                 do: {:ok, Map.put(snapshot, :source_key, {curve, public})}

          _ ->
            error
        end

      result ->
        result
    end
  end

  defp localize_import!(head, %{source_key: {curve, public}} = snapshot) do
    profile = Repo.get!(Atoll.Accounts.Profile, head.did)

    unless head.status == :deactivated and profile.import_curve == curve and
             profile.import_public_key == public,
           do: Repo.rollback(:invalid_swap)

    if profile.import_head == snapshot.head do
      {:ok, current} = Commit.verify(block!(head.head), head.did, head.curve, head.public_key)
      if current["data"].cid != snapshot.data, do: Repo.rollback(:stale_revision)
      %{snapshot | head: head.head, rev: head.rev}
    else
      if profile.import_rev && snapshot.rev <= profile.import_rev,
        do: Repo.rollback(:stale_revision)

      key =
        case Atoll.KeyVault.fetch(head.did) do
          {:ok, key} -> key
          {:error, reason} -> Repo.rollback(reason)
        end

      {:ok, rev} = TID.next(max(head.rev, snapshot.rev))
      {:ok, commit} = Commit.create(head.did, snapshot.data, rev, key)

      profile
      |> Ecto.Changeset.change(import_head: snapshot.head, import_rev: snapshot.rev)
      |> Repo.update!()

      blocks = snapshot.blocks |> Map.delete(snapshot.head) |> Map.put(commit.cid, commit.bytes)
      %{snapshot | head: commit.cid, rev: rev, blocks: blocks}
    end
  end

  defp localize_import!(_head, snapshot), do: snapshot

  def create(did, %SigningKey{} = key) do
    with true <- Syntax.did?(did),
         {:ok, derived} <- SigningKey.from_private(key.curve, key.private),
         true <- derived.public == key.public do
      Repo.transaction(fn ->
        Events.lock!()
        {:ok, tree} = MST.new()
        {:ok, rev} = TID.next()
        commit = persist_commit!(did, tree, rev, key)
        head = %{did: did, head: commit.cid, rev: rev, public_key: key.public, curve: key.curve}

        case Repo.insert_all(Head, [head], on_conflict: :nothing, conflict_target: [:did]) do
          {1, _} ->
            saved = Repo.get!(Head, did)
            remember_revision!(saved, Map.keys(tree.blocks))
            Events.append!(:commit, saved, Map.put(event_head(saved, nil), "ops", []))
            saved

          {0, _} ->
            Repo.rollback(:already_exists)
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
        Events.lock!()
        head = locked_head!(did, "FOR UPDATE")
        expected = Keyword.get(opts, :swap_commit, :any)
        if expected != :any and expected != head.head, do: Repo.rollback(:invalid_swap)
        unless matching_key?(key, head), do: Repo.rollback(:invalid_key)
        previous_records = record_map(did)
        updated = Enum.reduce(prepared, previous_records, &apply_operation!/2)
        {:ok, tree} = MST.new(updated)
        {:ok, rev} = TID.next(head.rev)
        Atoll.Blobs.References.apply_writes!(did, prepared, rev)
        commit = persist_commit!(did, tree, rev, key)
        Enum.each(prepared, &persist_record!(did, &1))
        updated_head = head |> Ecto.Changeset.change(head: commit.cid, rev: rev) |> Repo.update!()
        remember_revision!(updated_head, Map.keys(tree.blocks) ++ Map.values(tree.records))

        payload =
          Map.put(event_head(updated_head, head), "ops", event_ops(prepared, previous_records))

        Events.append!(:commit, updated_head, payload)
        updated_head
      end)
    end
  end

  def get_head(did) when is_binary(did) do
    case Repo.get(Head, did) do
      nil -> {:error, :not_found}
      head -> {:ok, head}
    end
  end

  @doc "Internal status control, serialized with repository writes. Caller must authorize administration."
  def set_status(did, status)
      when is_binary(did) and status in [:active, :deactivated, :takendown, :suspended] do
    Repo.transaction(fn ->
      Events.lock!()
      head = locked_head!(did, "FOR UPDATE", false)

      if head.status == status do
        head
      else
        attrs =
          if status == :takendown,
            do: [status: status, pre_takedown_status: head.status],
            else: [status: status, pre_takedown_status: nil, takedown_ref: nil]

        updated = head |> Ecto.Changeset.change(attrs) |> Repo.update!()

        Events.append!(:account, updated, %{
          "active" => status == :active,
          "status" => Atom.to_string(status)
        })

        updated
      end
    end)
  end

  def set_status(_, _), do: {:error, :invalid_status}

  def get_active_head(did) do
    with {:ok, head} <- get_head(did), :ok <- availability(head), do: {:ok, head}
  end

  def availability(%Head{status: :active}), do: :ok
  def availability(%Head{status: status}), do: {:error, {:repo_inactive, status}}

  def status_fields(%Head{status: :active} = head),
    do: %{did: head.did, active: true, rev: head.rev}

  def status_fields(%Head{} = head),
    do: %{did: head.did, active: false, status: Atom.to_string(head.status)}

  @doc "Lists collections that currently contain at least one record."
  def collections(did) do
    with {:ok, _} <- get_active_head(did) do
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
        Enum.map(
          page,
          &Map.merge(status_fields(&1), %{head: CID.to_base32(&1.head), rev: &1.rev})
        )
    }

    if length(rows) > limit, do: Map.put(result, :cursor, List.last(page).did), else: result
  end

  def get_record(did, path) when is_binary(did) and is_binary(path) do
    Repo.transaction(fn ->
      locked_head!(did, "FOR SHARE")
      Takedowns.ensure_visible!(did, path)

      case read_record(did, path) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Reads a record version proven to belong to this path in a retained signed revision."
  def get_record(did, path, nil), do: get_record(did, path)

  def get_record(did, path, cid) do
    with true <- Syntax.repo_path?(path),
         {:ok, %{codec: :dag_cbor}} <- CID.decode(cid) do
      Repo.transaction(fn ->
        head = locked_head!(did, "FOR SHARE")

        Takedowns.ensure_visible!(did, path)

        # Block membership alone is insufficient: a CID could belong to another path.
        revisions =
          from r in Revision,
            where: r.did == ^did and ^cid in r.blocks,
            order_by: [desc: r.rev]

        found? =
          revisions
          |> Repo.stream(max_rows: 1)
          |> Enum.any?(fn revision ->
            with {:ok, commit} <-
                   Commit.verify(block!(revision.head), did, head.curve, head.public_key),
                 true <- commit["rev"] == revision.rev,
                 blocks = Map.new(revision.blocks, &{&1, block!(&1)}),
                 {:ok, tree} <- MST.load(commit["data"].cid, blocks) do
              Map.get(tree.records, path) == cid
            else
              _ -> Repo.rollback(:invalid_repository)
            end
          end)

        unless found?, do: Repo.rollback(:not_found)

        case record_value(did, path, cid) do
          {:ok, record} -> record
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp read_record(did, path) do
    case Repo.get_by(Record, did: did, path: path) do
      nil ->
        {:error, :not_found}

      record ->
        record_value(did, path, record.cid)
    end
  end

  defp record_value(did, path, cid) do
    with {:ok, value} <- Storage.get_node(cid),
         {:ok, json} <- DataModel.to_json(value) do
      {:ok, %{uri: "at://" <> did <> "/" <> path, cid: cid, value: json}}
    end
  end

  @doc "Lists current records in bytewise key order. Options are validated by the HTTP boundary."
  def list_records(did, collection, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    reverse = Keyword.get(opts, :reverse, false)
    cursor = Keyword.get(opts, :cursor)
    prefix = collection <> "/"
    upper = collection <> "0"

    Repo.transaction(fn ->
      locked_head!(did, "FOR SHARE")

      query =
        from r in Record,
          join: b in Atoll.Storage.Block,
          on: b.cid == r.cid,
          left_join: t in Takedown,
          on: t.did == r.did and t.path == r.path,
          where: r.did == ^did and is_nil(t.path),
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

          result

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Exports a consistent snapshot or the current blocks absent from a retained revision.
  Unknown revisions fall back to a full export. The current commit is always included.
  Deleted records are not sent; the new MST proves the current state. Revision block
  sets remain until operator compaction; streaming remains pending.
  """
  def export(did, since \\ nil, token \\ nil) do
    Repo.transaction(fn ->
      unless is_nil(since) or TID.valid?(since), do: Repo.rollback(:invalid_request)

      if not is_nil(token) do
        case Atoll.Accounts.Sessions.authenticate_export(token, did) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      {head, tree, commit} = snapshot!(did, is_nil(token))

      known =
        case since && Repo.get_by(Revision, did: did, rev: since) do
          %Revision{blocks: blocks} -> MapSet.new(blocks)
          _ -> MapSet.new()
        end

      tree_blocks = Map.reject(tree.blocks, fn {cid, _} -> MapSet.member?(known, cid) end)

      blocks =
        Enum.reduce(Map.values(tree.records), tree_blocks, fn cid, acc ->
          if MapSet.member?(known, cid), do: acc, else: Map.put(acc, cid, block!(cid))
        end)

      archive!([head.head], Map.put(blocks, head.head, commit))
    end)
  end

  @doc """
  Consumes a lazy CAR inside a consistent, authorized snapshot transaction.

  The callback must consume the enumerable before returning. Repository metadata
  and MST nodes remain in memory; record bodies are read one at a time. A shared
  head lock pins the snapshot until completion or cancellation. Lazy read failures
  raise to abort an already-started transfer, rather than returning a JSON error.
  """
  def stream_export(did, since, token, consume) when is_function(consume, 1) do
    Repo.transaction(
      fn ->
        unless is_nil(since) or TID.valid?(since), do: Repo.rollback(:invalid_request)

        if not is_nil(token) do
          case Atoll.Accounts.Sessions.authenticate_export(token, did) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        {head, tree, commit} = snapshot!(did, is_nil(token))

        if not is_nil(token) do
          case Atoll.Accounts.Sessions.authenticate_export(token, did) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        known =
          case since && Repo.get_by(Revision, did: did, rev: since) do
            %Revision{blocks: blocks} -> MapSet.new(blocks)
            _ -> MapSet.new()
          end

        nodes = Stream.reject(tree.blocks, fn {cid, _} -> MapSet.member?(known, cid) end)

        records =
          tree.records
          |> Map.values()
          |> Enum.uniq()
          |> Stream.reject(
            &(MapSet.member?(known, &1) or Map.has_key?(tree.blocks, &1) or &1 == head.head)
          )
          |> Stream.map(fn cid ->
            case Storage.get_block(cid) do
              {:ok, bytes} -> {cid, bytes}
              _ -> raise "Repository stream contains a missing block"
            end
          end)

        blocks = Stream.concat([[{head.head, commit}], nodes, records])
        {:ok, stream} = CAR.encode_stream([head.head], blocks)
        consume.(stream)
      end,
      timeout: 60_000
    )
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

  @doc "Exports requested blocks proven reachable from current or retained signed repository revisions."
  def export_blocks(did, cids) when is_list(cids) and length(cids) in 1..100 do
    Repo.transaction(fn ->
      {head, tree, commit} = snapshot!(did)
      available = MapSet.new([head.head | Map.keys(tree.blocks) ++ Map.values(tree.records)])
      missing = MapSet.difference(MapSet.new(cids), available)
      verify_historical_blocks!(head, missing)

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

  defp verify_historical_blocks!(head, missing) do
    if MapSet.size(missing) > 0 do
      requested = MapSet.to_list(missing)

      revisions =
        from r in Revision,
          where: r.did == ^head.did,
          where: fragment("? && ?", r.blocks, type(^requested, {:array, :binary})),
          order_by: [desc: r.rev]

      remaining =
        revisions
        |> Repo.stream(max_rows: 1)
        |> Enum.reduce_while(missing, fn revision, remaining ->
          # Revision indexes narrow the search but do not establish membership.
          with {:ok, commit} <-
                 Commit.verify(block!(revision.head), head.did, head.curve, head.public_key),
               true <- commit["rev"] == revision.rev,
               blocks = Map.new(revision.blocks, &{&1, block!(&1)}),
               {:ok, tree} <- MST.load(commit["data"].cid, blocks) do
            reachable =
              MapSet.new([revision.head | Map.keys(tree.blocks) ++ Map.values(tree.records)])

            remaining = MapSet.difference(remaining, reachable)
            if MapSet.size(remaining) == 0, do: {:halt, remaining}, else: {:cont, remaining}
          else
            _ -> Repo.rollback(:invalid_repository)
          end
        end)

      if MapSet.size(remaining) > 0, do: Repo.rollback(:block_not_found)
    end
  end

  defp snapshot!(did, require_active \\ true) do
    head = locked_head!(did, "FOR SHARE", require_active)
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

  defp event_head(head, previous) do
    %{
      "commit" => %CBOR.Link{cid: head.head},
      "rev" => head.rev,
      "since" => previous && previous.rev,
      "previousCommit" => previous && %CBOR.Link{cid: previous.head}
    }
  end

  defp event_ops(prepared, previous) do
    Enum.flat_map(prepared, fn {action, path, cid, _} ->
      old = Map.get(previous, path)

      if action == :delete and is_nil(old) do
        []
      else
        action =
          cond do
            action == :delete -> "delete"
            is_nil(old) -> "create"
            true -> "update"
          end

        [
          %{
            "action" => action,
            "path" => path,
            "cid" => cid && %CBOR.Link{cid: cid},
            "prev" => old && %CBOR.Link{cid: old}
          }
        ]
      end
    end)
  end

  defp remember_revision!(head, cids) do
    Repo.insert!(%Revision{
      did: head.did,
      rev: head.rev,
      head: head.head,
      blocks: Enum.uniq([head.head | cids])
    })

    Atoll.Repositories.Quota.check!(head.did)
  end

  defp locked_head!(did, lock, require_active \\ true) do
    query = from h in Head, where: h.did == ^did

    query =
      case lock do
        "FOR UPDATE" -> from h in query, lock: "FOR UPDATE"
        "FOR SHARE" -> from h in query, lock: "FOR SHARE"
      end

    head = Repo.one(query) || Repo.rollback(:not_found)

    if require_active do
      case availability(head) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end

    head
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
