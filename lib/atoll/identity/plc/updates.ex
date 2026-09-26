defmodule Atoll.Identity.PLC.Updates do
  @moduledoc """
  Internal durable journal for authorized ordinary PLC updates.

  Staging verifies supplied audit evidence but does not authenticate the caller or
  prove directory freshness. Callers authorize and stage with local reservations in
  one transaction, submit after commit, then complete with their local state change.
  Never replace or delete a pending signed operation after an ambiguous submission.
  """
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Repositories.{Events, Head}
  alias Atoll.Identity.PLC.{AuditLog, Client, Operation, Update}

  def stage(did, audit, operation) when is_map(operation) do
    with {:ok, %{operation: previous, tombstoned: false}} <- AuditLog.verify(did, audit),
         true <- operation["type"] == "plc_operation",
         {:ok, _} <- Operation.verify_update(previous, operation),
         {:ok, cid} <- Operation.cid(operation) do
      Repo.transaction(fn ->
        lock_head!(did)

        case Repo.get_by(Update, did: did, cid: cid) do
          %Update{} = row ->
            summary(row)

          nil ->
            if Repo.exists?(from u in Update, where: u.did == ^did and is_nil(u.completed_at)),
              do: Repo.rollback(:plc_update_pending)

            Repo.insert!(%Update{did: did, cid: cid, previous: previous, operation: operation})
            |> summary()
        end
      end)
    else
      {:ok, %{tombstoned: true}} -> {:error, :did_not_found}
      false -> {:error, :invalid_plc_operation}
      error -> error
    end
  end

  def stage(_, _, _), do: {:error, :invalid_plc_operation}

  def submit(did, cid, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :plc_update_inside_transaction}
    else
      case Repo.get_by(Update, did: did, cid: cid) do
        nil -> {:error, :plc_update_not_found}
        %Update{confirmed_at: time} = row when not is_nil(time) -> {:ok, summary(row)}
        row -> submit_row(row, opts)
      end
    end
  end

  defp submit_row(row, opts) do
    with {:ok, cid} <- Operation.cid(row.operation),
         true <- cid == row.cid,
         :ok <-
           Client.submit_update(row.did, row.previous, row.operation, Keyword.take(opts, [:plug])) do
      Repo.transaction(fn ->
        lock_head!(row.did)
        current = Repo.get_by(Update, did: row.did, cid: row.cid)

        unless current && current.operation == row.operation && current.previous == row.previous,
          do: Repo.rollback(:plc_update_not_found)

        if current.confirmed_at do
          summary(current)
        else
          current
          |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now())
          |> Repo.update!()
          |> summary()
        end
      end)
    else
      false -> {:error, :invalid_plc_operation}
      error -> error
    end
  end

  @doc "Mark local completion inside the caller's transaction after its authorized local mutation."
  def complete!(did, cid) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "PLC completion requires a transaction")

    lock_head!(did)
    row = Repo.get_by(Update, did: did, cid: cid) || Repo.rollback(:plc_update_not_found)
    unless row.confirmed_at, do: Repo.rollback(:plc_update_unconfirmed)

    if row.completed_at do
      summary(row)
    else
      row
      |> Ecto.Changeset.change(completed_at: DateTime.utc_now())
      |> Repo.update!()
      |> summary()
    end
  end

  defp lock_head!(did) do
    Events.lock!()

    Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
      Repo.rollback(:account_not_found)
  end

  defp summary(row),
    do: %{
      did: row.did,
      cid: row.cid,
      confirmed: not is_nil(row.confirmed_at),
      completed: not is_nil(row.completed_at)
    }
end
