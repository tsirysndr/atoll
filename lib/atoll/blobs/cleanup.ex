defmodule Atoll.Blobs.Cleanup do
  @moduledoc """
  Internal bounded expiration and durable byte cleanup, with an opt-in scheduler.

  Uploads, withdrawals, expiration and collection share the repository write lock.
  S3 deletion runs under that lock and only when no account owns that backend/CID.
  Failed deletes stay queued. S3 objects orphaned before metadata committed and
  blobs withdrawn before this queue existed require a future inventory sweep.
  """
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Blobs.{Blob, CleanupJob, Reference, S3}
  alias Atoll.Repositories.Events

  @doc false
  def enqueue!(blobs) do
    rows = Enum.map(blobs, &%{cid: &1.cid, backend: &1.backend, queued_at: DateTime.utc_now()})
    Repo.insert_all(CleanupJob, rows, on_conflict: :nothing, conflict_target: [:cid, :backend])
    :ok
  end

  @doc "Expire a bounded batch of unreferenced uploads; default grace is 24 hours, minimum one hour."
  def expire_staged(opts \\ []) do
    grace = Keyword.get(opts, :grace_seconds, 86_400)
    limit = Keyword.get(opts, :limit, 100)
    actor = Keyword.get(opts, :actor, "operator")

    if is_integer(grace) and grace >= 3600 and is_integer(limit) and limit in 1..1000 and
         actor in ["operator", "worker"] do
      cutoff = DateTime.add(DateTime.utc_now(), -grace, :second)

      candidates = staged_candidates(cutoff, limit)

      if actor == "worker" and not Repo.exists?(candidates) do
        {:ok, 0}
      else
        Repo.transaction(fn ->
          Atoll.Database.limits!(1_000, 5_000)
          cleanup_lock!(actor)
          blobs = Repo.all(candidates)

          enqueue!(blobs)
          delete_expired!(blobs)

          if actor == "operator" or blobs != [],
            do: Atoll.Moderation.Audit.staged_blob_expiration!(limit, grace, cutoff, blobs, actor)

          length(blobs)
        end)
      end
    else
      {:error, :invalid_cleanup_options}
    end
  rescue
    error in [Postgrex.Error, Exqlite.Error] -> cleanup_error(error, __STACKTRACE__)
  end

  defp staged_candidates(cutoff, limit) do
    referenced =
      from r in Reference,
        where: r.did == parent_as(:blob).did and r.cid == parent_as(:blob).cid,
        select: 1

    from b in Blob,
      as: :blob,
      where: b.staged_at < ^cutoff,
      where: not exists(subquery(referenced)),
      order_by: [b.staged_at, b.did, b.cid],
      limit: ^limit
  end

  defp delete_expired!([]), do: :ok

  defp delete_expired!(blobs) do
    # Selection and deletion hold the publication lock. Delete this bounded
    # set in one round trip instead of holding the lock across one DELETE for
    # every expired upload.
    selected =
      Enum.reduce(blobs, dynamic(false), fn blob, selected ->
        dynamic([b], ^selected or (b.did == ^blob.did and b.cid == ^blob.cid))
      end)

    Repo.delete_all(from b in Blob, where: ^selected)
  end

  @doc "Delete queued unowned bytes, using one transaction per item. Must not run inside a caller transaction."
  def collect(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    actor = Keyword.get(opts, :actor, "operator")

    cond do
      Repo.in_transaction?() ->
        {:error, :cleanup_requires_own_transaction}

      not is_integer(limit) or limit not in 1..1000 or actor not in ["operator", "worker"] ->
        {:error, :invalid_cleanup_options}

      true ->
        config =
          Keyword.get(
            opts,
            :storage,
            Application.get_env(:atoll, :blob_storage, backend: :postgres)
          )

        jobs =
          Repo.all(from j in CleanupJob, order_by: [j.queued_at, j.cid, j.backend], limit: ^limit)

        if jobs == [] and actor == "worker" do
          {:ok, %{deleted: 0, retained: 0, failed: 0, skipped: 0}}
        else
          collect_batch(jobs, limit, config, actor)
        end
    end
  rescue
    error in [Postgrex.Error, Exqlite.Error] -> cleanup_error(error, __STACKTRACE__)
  end

  defp collect_batch(jobs, limit, config, actor) do
    with {:ok, attempt} <-
           audit_transaction(
             fn ->
               Atoll.Moderation.Audit.blob_collection_attempt!(limit, jobs, actor)
             end,
             actor
           ) do
      result =
        Enum.reduce_while(jobs, {:ok, %{deleted: 0, retained: 0, failed: 0, skipped: 0}}, fn job,
                                                                                             {:ok,
                                                                                              counts} ->
          case collect_one(job, config, attempt.id, actor) do
            {:ok, result} -> {:cont, {:ok, Map.update!(counts, result, &(&1 + 1))}}
            {:error, _} = error -> {:halt, error}
          end
        end)

      with {:ok, counts} <- result,
           {:ok, _} <-
             audit_transaction(
               fn ->
                 Atoll.Moderation.Audit.blob_collection_completed!(attempt.id, counts, actor)
               end,
               actor
             ),
           do: {:ok, counts}
    end
  end

  defp audit_transaction(function, actor) do
    Repo.transaction(fn ->
      Atoll.Database.limits!(1_000, 5_000)
      if actor == "worker", do: cleanup_lock!(actor)
      function.()
    end)
  end

  defp collect_one(job, config, attempt_id, actor) do
    audit_transaction(
      fn ->
        Events.lock!()
        current = Repo.get_by(CleanupJob, cid: job.cid, backend: job.backend)

        result =
          cond do
            is_nil(current) ->
              :skipped

            Repo.exists?(from b in Blob, where: b.cid == ^job.cid and b.backend == ^job.backend) ->
              Repo.delete!(current)
              :retained

            true ->
              case delete_bytes(job, config) do
                :ok ->
                  Repo.delete!(current)
                  :deleted

                {:error, _} ->
                  # Move failures behind older work so one bad object cannot starve the queue.
                  current
                  |> Ecto.Changeset.change(queued_at: DateTime.utc_now())
                  |> Repo.update!()

                  :failed
              end
          end

        Atoll.Moderation.Audit.blob_collection_item!(attempt_id, job, result, actor)
        result
      end,
      actor
    )
  end

  defp cleanup_lock!("worker") do
    unless Events.try_lock!(), do: Repo.rollback(:cleanup_busy)
  end

  defp cleanup_lock!(_actor), do: Events.lock!()

  defp cleanup_error(error, stacktrace) do
    if Atoll.Database.error_code(error) in [:lock_not_available, :query_canceled],
      do: {:error, :cleanup_busy},
      else: reraise(error, stacktrace)
  end

  defp delete_bytes(%{backend: :postgres, cid: cid}, _) do
    Repo.delete_all(from b in Atoll.Storage.Block, where: b.cid == ^cid)
    :ok
  end

  defp delete_bytes(%{backend: :s3, cid: cid}, config),
    do: S3.delete(cid, Keyword.get(config, :s3, []))
end
