defmodule Atoll.Identity.PLC.Recoveries do
  @moduledoc """
  Internal durable journal for preflighted recovery forks, separate from ordinary updates.

  Callers must authorize staging and coordinate local completion. The reviewed
  head and displaced suffix are immutable; no automatic rebase expands recovery.
  Confirmation records acceptance only, never fresh authority for local completion.
  """
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Repositories.{Events, Head}
  alias Atoll.Identity.PLC.{Client, Operation, RecoveryPlan, Update}

  def stage(did, audit, operation, now \\ DateTime.utc_now()) do
    with {:ok, plan} <- RecoveryPlan.preview(did, audit, operation, now) do
      previous = Enum.find(audit, &(&1["cid"] == plan.previous))["operation"]

      Repo.transaction(fn ->
        lock!(did)

        case Repo.get_by(Update, did: did, cid: plan.cid) do
          nil ->
            if Repo.exists?(
                 from u in Update,
                   where: u.did == ^did and is_nil(u.completed_at) and is_nil(u.nullified_at)
               ),
               do: Repo.rollback(:plc_update_pending)

            Repo.insert!(%Update{
              did: did,
              cid: plan.cid,
              previous: previous,
              operation: operation,
              recovery_expected_head: plan.expected_head,
              recovery_deadline: plan.valid_until,
              recovery_nullified_cids: plan.nullified_cids
            })
            |> summary()

          %Update{nullified_at: time} when not is_nil(time) ->
            Repo.rollback(:plc_update_nullified)

          row ->
            unless row.operation == operation and row.previous == previous and
                     row.recovery_expected_head == plan.expected_head and
                     row.recovery_nullified_cids == plan.nullified_cids and
                     DateTime.compare(row.recovery_deadline, plan.valid_until) == :eq,
                   do: Repo.rollback(:plc_recovery_conflict)

            summary(row)
        end
      end)
    end
  end

  def submit(did, cid, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :plc_update_inside_transaction}
    else
      case Repo.get_by(Update, did: did, cid: cid) do
        %Update{nullified_at: time} when not is_nil(time) ->
          {:error, :plc_update_nullified}

        %Update{recovery_expected_head: expected} = row when is_binary(expected) ->
          submit_row(row, opts)

        _ ->
          {:error, :plc_recovery_not_found}
      end
    end
  end

  defp submit_row(row, opts) do
    with {:ok, cid} <- Operation.cid(row.operation),
         true <- cid == row.cid,
         :ok <-
           Client.submit_recovery(
             row.did,
             %{
               expected_head: row.recovery_expected_head,
               valid_until: row.recovery_deadline,
               nullified_cids: row.recovery_nullified_cids
             },
             row.operation,
             Keyword.take(opts, [:plug])
           ) do
      Repo.transaction(fn ->
        lock!(row.did)

        current =
          Repo.get_by(Update, did: row.did, cid: row.cid) ||
            Repo.rollback(:plc_recovery_not_found)

        unless current.operation == row.operation and current.previous == row.previous and
                 current.recovery_expected_head == row.recovery_expected_head and
                 current.recovery_nullified_cids == row.recovery_nullified_cids and
                 current.recovery_deadline == row.recovery_deadline,
               do: Repo.rollback(:plc_recovery_conflict)

        if current.nullified_at, do: Repo.rollback(:plc_update_nullified)

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

  defp lock!(did) do
    Events.lock!()

    Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
      Repo.rollback(:account_not_found)
  end

  defp summary(row),
    do: %{
      did: row.did,
      cid: row.cid,
      expected_head: row.recovery_expected_head,
      valid_until: row.recovery_deadline,
      nullified_cids: row.recovery_nullified_cids,
      confirmed: not is_nil(row.confirmed_at),
      completed: not is_nil(row.completed_at)
    }
end
