defmodule Atoll.Identity.PLC.NullifiedUpdates do
  @moduledoc "Operator closure of pending work explicitly nullified by verified PLC history."
  import Ecto.Query
  alias Atoll.Repo
  alias Atoll.Identity.HandleReservation
  alias Atoll.Identity.PLC.{Client, Operation, Update}
  alias Atoll.Repositories.{Events, Head}

  def reconcile(did, cid, expected_head, opts \\ []) do
    with false <- Repo.in_transaction?(),
         {:ok, %{entries: entries, state: state}} <-
           Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         true <- state.cid == expected_head,
         true <- cid in state.nullified_cids,
         entry when not is_nil(entry) <- Enum.find(entries, &(&1["cid"] == cid)) do
      Repo.transaction(fn ->
        Events.lock!()

        head =
          Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
            Repo.rollback(:account_not_found)

        unless head.status in [:active, :deactivated], do: Repo.rollback(:repo_inactive)
        row = Repo.get_by(Update, did: did, cid: cid) || Repo.rollback(:plc_update_not_found)

        unless row.operation == entry["operation"] and Operation.cid(row.operation) == {:ok, cid},
          do: Repo.rollback(:plc_conflict)

        if row.completed_at, do: Repo.rollback(:plc_update_completed)

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

          Atoll.Moderation.Audit.nullified_update!(row, state.cid, reservations)
        end

        %{
          did: did,
          cid: cid,
          observed_head: state.cid,
          result: if(row.nullified_at, do: :already_nullified, else: :nullified)
        }
      end)
    else
      true -> {:error, :plc_update_inside_transaction}
      false -> {:error, :plc_conflict}
      nil -> {:error, :plc_conflict}
      error -> error
    end
  end
end
