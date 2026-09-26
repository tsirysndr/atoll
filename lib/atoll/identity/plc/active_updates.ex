defmodule Atoll.Identity.PLC.ActiveUpdates do
  @moduledoc "Operator reconciliation of ordinary pending updates retained in verified active PLC history."
  import Ecto.Query
  alias Atoll.{CBOR, KeyVault, Multikey, Repo}
  alias Atoll.Accounts.{Profile, Signup}
  alias Atoll.Identity.{Handle, HandleReservation, Observation}
  alias Atoll.Identity.PLC.{Client, Operation, Update, Updates}
  alias Atoll.Repositories.{Events, Head}

  def reconcile(did, cid, expected_head, opts \\ []) do
    with false <- Repo.in_transaction?(),
         {:ok, %{entries: entries, state: %{tombstoned: false} = state}} <-
           Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         true <- state.cid == expected_head and cid in state.active_cids,
         entry when not is_nil(entry) <- Enum.find(entries, &(&1["cid"] == cid)),
         ["at://" <> handle] <- entry["operation"]["alsoKnownAs"],
         true <-
           Signup.hosted_handle?(handle) or
             Handle.resolve(handle, Keyword.put(opts, :force_refresh, true)) == {:ok, did} do
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '1s'")
        Repo.query!("SET LOCAL statement_timeout = '5s'")
        Events.lock!()

        head =
          Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
            Repo.rollback(:account_not_found)

        unless head.status in [:active, :deactivated], do: Repo.rollback(:repo_inactive)
        if Signup.pending?(did), do: Repo.rollback(:signup_pending)
        row = Repo.get_by(Update, did: did, cid: cid) || Repo.rollback(:plc_update_not_found)
        if row.nullified_at, do: Repo.rollback(:plc_update_nullified)

        if row.signing_public_key || row.authority_public_key || row.recovery_expected_head,
          do: Repo.rollback(:plc_update_pending)

        unless row.operation == entry["operation"] and Operation.cid(row.operation) == {:ok, cid},
          do: Repo.rollback(:plc_conflict)

        unwrap!(Operation.verify_update(row.previous, row.operation))
        predecessor = unwrap!(Operation.successor(row.previous))
        {:ok, public} = Multikey.to_did_key(head.curve, head.public_key)
        check_identity!(row.operation, public, handle)
        check_identity!(state.operation, public, handle)
        unwrap!(KeyVault.fetch(did))
        profile = Repo.get(Profile, did) || Repo.rollback(:account_not_found)
        reservation = Repo.get_by(HandleReservation, did: did)

        if reservation && (reservation.cid != cid or reservation.handle != handle),
          do: Repo.rollback(:plc_update_pending)

        if row.completed_at do
          unless profile.handle == handle, do: Repo.rollback(:plc_conflict)
        else
          if profile.handle != handle do
            unless reservation &&
                     List.first(predecessor["alsoKnownAs"] || []) ==
                       "at://" <> (profile.handle || ""),
                   do: Repo.rollback(:plc_conflict)

            if Repo.exists?(from p in Profile, where: p.handle == ^handle and p.did != ^did),
              do: Repo.rollback(:handle_not_available)

            profile |> Ecto.Changeset.change(handle: handle) |> Repo.update!()
          end

          fingerprint =
            :crypto.hash(
              :sha256,
              CBOR.encode!(%{
                "handle" => handle,
                "claimedHandle" => handle,
                "pds" => AtollWeb.Endpoint.url(),
                "curve" => Atom.to_string(head.curve),
                "key" => %CBOR.Bytes{data: head.public_key}
              })
            )

          Repo.insert!(%Observation{did: did, handle: handle, fingerprint: fingerprint},
            on_conflict: {:replace, [:handle, :fingerprint]},
            conflict_target: [:did]
          )

          if is_nil(row.confirmed_at),
            do: row |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now()) |> Repo.update!()

          Updates.complete!(did, cid)
          Repo.delete_all(from r in HandleReservation, where: r.did == ^did and r.cid == ^cid)
          Events.append!(:identity, head, %{"handle" => handle})
          Atoll.Moderation.Audit.active_update!(row, state.cid, profile.handle, handle)
        end

        %{
          did: did,
          cid: cid,
          observed_head: state.cid,
          result: if(row.completed_at, do: :already_completed, else: :completed)
        }
      end)
    else
      true -> {:error, :plc_update_inside_transaction}
      {:error, _} = error -> error
      _ -> {:error, :plc_conflict}
    end
  end

  defp check_identity!(operation, key, handle) do
    unless operation["type"] == "plc_operation" and
             List.first(operation["alsoKnownAs"] || []) == "at://" <> handle and
             get_in(operation, ["verificationMethods", "atproto"]) == key and
             get_in(operation, ["services", "atproto_pds"]) == %{
               "type" => "AtprotoPersonalDataServer",
               "endpoint" => AtollWeb.Endpoint.url()
             },
           do: Repo.rollback(:plc_conflict)
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
