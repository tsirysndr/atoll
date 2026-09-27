defmodule Atoll.Identity.PLC.AbsentUpdates do
  @moduledoc """
  Operator closure of pending work absent from fresh verified directory history.

  Covers submissions the directory never recorded and journals stranded by an
  incompatible directory identity, including tombstones. Closure requires that
  the operation can no longer land at the reviewed head: its signed predecessor
  is not the surviving head anymore, so acceptance would need a directory fork
  reviewed as a recovery instead. Explicitly nullified operations use the
  dedicated nullification reconciliation; recovery journals keep their own
  expected-head workflow.
  """
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Identity.HandleReservation
  alias Atoll.Identity.PLC.{Client, Operation, Update}
  alias Atoll.Repositories.{Events, Head}

  def reconcile(did, cid, expected_head, opts \\ []) do
    with false <- Repo.in_transaction?(),
         true <-
           is_binary(cid) and byte_size(cid) in 1..128 and is_binary(expected_head) and
             byte_size(expected_head) in 1..128,
         {:ok, %{state: state}} <- Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         true <- state.cid == expected_head,
         true <- cid not in state.active_cids and cid not in state.nullified_cids do
      Repo.transaction(fn ->
        Events.lock!()

        head =
          Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
            Repo.rollback(:account_not_found)

        unless head.status in [:active, :deactivated], do: Repo.rollback(:repo_inactive)
        row = Repo.get_by(Update, did: did, cid: cid) || Repo.rollback(:plc_update_not_found)
        if row.completed_at, do: Repo.rollback(:plc_update_completed)
        if row.recovery_expected_head, do: Repo.rollback(:plc_conflict)

        unless is_map(row.previous) and Operation.cid(row.operation) == {:ok, cid},
          do: Repo.rollback(:plc_conflict)

        unless state.tombstoned or superseded?(row, state),
          do: Repo.rollback(:plc_update_pending)

        unless row.nullified_at do
          row
          |> Ecto.Changeset.change(
            nullified_at: DateTime.utc_now(),
            nullified_head: state.cid,
            signing_envelope: nil,
            authority_envelope: nil
          )
          |> Repo.update!(log: false)

          {reservations, _} =
            Repo.delete_all(from r in HandleReservation, where: r.did == ^did and r.cid == ^cid)

          Atoll.Moderation.Audit.absent_update!(row, state, reservations)
        end

        %{
          did: did,
          cid: cid,
          observed_head: state.cid,
          tombstoned: state.tombstoned,
          result: if(row.nullified_at, do: :already_closed, else: :closed)
        }
      end)
    else
      true -> {:error, :plc_update_inside_transaction}
      false -> {:error, :plc_conflict}
      error -> error
    end
  end

  defp superseded?(row, state) do
    case Operation.cid(row.previous) do
      {:ok, previous} -> previous != state.cid
      _ -> false
    end
  end
end
