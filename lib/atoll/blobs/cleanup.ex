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

    if is_integer(grace) and grace >= 3600 and is_integer(limit) and limit in 1..1000 do
      cutoff = DateTime.add(DateTime.utc_now(), -grace, :second)

      Repo.transaction(fn ->
        Events.lock!()

        referenced =
          from r in Reference,
            where: r.did == parent_as(:blob).did and r.cid == parent_as(:blob).cid,
            select: 1

        blobs =
          Repo.all(
            from b in Blob,
              as: :blob,
              where: b.staged_at < ^cutoff,
              where: not exists(subquery(referenced)),
              order_by: [b.staged_at, b.did, b.cid],
              limit: ^limit
          )

        enqueue!(blobs)
        Enum.each(blobs, &Repo.delete!/1)
        length(blobs)
      end)
    else
      {:error, :invalid_cleanup_options}
    end
  end

  @doc "Delete queued unowned bytes, using one transaction per item. Must not run inside a caller transaction."
  def collect(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    cond do
      Repo.in_transaction?() ->
        {:error, :cleanup_requires_own_transaction}

      not is_integer(limit) or limit not in 1..1000 ->
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

        counts =
          Enum.reduce(jobs, %{deleted: 0, retained: 0, failed: 0, skipped: 0}, fn job, counts ->
            {:ok, result} = collect_one(job, config)
            Map.update!(counts, result, &(&1 + 1))
          end)

        {:ok, counts}
    end
  end

  defp collect_one(job, config) do
    Repo.transaction(fn ->
      Events.lock!()
      current = Repo.get_by(CleanupJob, cid: job.cid, backend: job.backend)

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
              current |> Ecto.Changeset.change(queued_at: DateTime.utc_now()) |> Repo.update!()
              :failed
          end
      end
    end)
  end

  defp delete_bytes(%{backend: :postgres, cid: cid}, _) do
    Repo.delete_all(from b in Atoll.Storage.Block, where: b.cid == ^cid)
    :ok
  end

  defp delete_bytes(%{backend: :s3, cid: cid}, config),
    do: S3.delete(cid, Keyword.get(config, :s3, []))
end
