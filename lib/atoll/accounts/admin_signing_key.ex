defmodule Atoll.Accounts.AdminSigningKey do
  @moduledoc "Audited operator-only PLC directory signing-key updates; does not replace local private custody."
  import Ecto.Query
  alias Atoll.{Multikey, Repo, Syntax}
  alias Atoll.Identity.PLC.{Client, Operation, Registrations, Update, Updates}
  alias Atoll.Repositories.{Events, Head}

  def update(params, opts \\ [])

  def update(%{"did" => "did:plc:" <> _ = did, "signingKey" => key} = params, opts)
      when map_size(params) == 2 do
    with false <- Repo.in_transaction?(),
         true <- Syntax.did?(did),
         {:ok, _} <- Multikey.from_did_key(key),
         {:ok, pending} <-
           transaction(fn ->
             lock!(did)
             pending(did)
           end),
         {:ok, result} <- prepare(did, key, pending, opts) do
      case result do
        :unchanged -> {:ok, :unchanged}
        %Update{} = row -> publish(row, opts)
      end
    else
      true -> {:error, :plc_update_inside_transaction}
      false -> {:error, :invalid_request}
      {:error, :invalid_multikey} -> {:error, :invalid_request}
      error -> error
    end
  end

  def update(_, _), do: {:error, :invalid_request}

  defp prepare(_, key, %Update{directory_key_update: true} = row, _) do
    if target(row.operation) == key, do: {:ok, row}, else: {:error, :plc_update_pending}
  end

  defp prepare(_, _, %Update{}, _), do: {:error, :plc_update_pending}

  defp prepare(did, key, nil, opts) do
    with {:ok, %{entries: audit, state: %{tombstoned: false} = state}} <-
           Client.fetch_audit(did, opts),
         {:ok, successor} <- Operation.successor(state.operation) do
      transaction(fn ->
        lock!(did)
        if pending(did), do: Repo.rollback(:plc_update_pending)

        if target(successor) == key do
          Atoll.Moderation.Audit.directory_signing_key!(did, state.cid, key, key, :unchanged)
          :unchanged
        else
          rotation = unwrap!(Registrations.rotation_key(did))

          operation =
            unwrap!(
              Operation.sign(put_in(successor, ["verificationMethods", "atproto"], key), rotation)
            )

          staged = unwrap!(Updates.stage(did, audit, operation))
          row = Repo.get_by!(Update, did: did, cid: staged.cid)
          # A completed historical operation cannot become a new pending request.
          if row.completed_at, do: Repo.rollback(:plc_update_completed)
          row = row |> Ecto.Changeset.change(directory_key_update: true) |> Repo.update!()

          Atoll.Moderation.Audit.directory_signing_key!(
            did,
            row.cid,
            target(row.previous),
            key,
            :staged
          )

          row
        end
      end)
    else
      {:ok, _} -> {:error, :plc_conflict}
      error -> error
    end
  end

  defp publish(row, opts) do
    with {:ok, _} <- Updates.submit(row.did, row.cid, opts),
         {:ok, %{state: %{tombstoned: false} = state}} <- Client.fetch_audit(row.did, opts),
         true <- state.cid == row.cid and state.operation == row.operation do
      transaction(fn ->
        head = lock!(row.did)

        current =
          Repo.get_by(Update, did: row.did, cid: row.cid) || Repo.rollback(:plc_update_not_found)

        unless current.directory_key_update and is_nil(current.nullified_at) and
                 current.operation == row.operation and current.confirmed_at,
               do: Repo.rollback(:plc_conflict)

        unless current.completed_at do
          Atoll.Moderation.Audit.directory_signing_key!(
            row.did,
            row.cid,
            target(row.previous),
            target(row.operation),
            :completed
          )

          # The notification asks consumers to re-resolve the DID without making
          # a new claim about a handle or changing local repository key custody.
          Events.append!(:identity, head, %{})
          Updates.complete!(row.did, row.cid)
        end

        :updated
      end)
    else
      false -> {:error, :plc_conflict}
      {:ok, _} -> {:error, :plc_conflict}
      error -> error
    end
  end

  defp pending(did),
    do:
      Repo.one(
        from u in Update,
          where: u.did == ^did and is_nil(u.completed_at) and is_nil(u.nullified_at)
      )

  defp lock!(did) do
    Events.lock!()

    head =
      Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
        Repo.rollback(:admin_account_not_found)

    if Atoll.Accounts.Signup.pending?(did), do: Repo.rollback(:signup_pending)
    head
  end

  defp transaction(action) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      action.()
    end)
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :admin_busy},
        else: reraise(e, __STACKTRACE__)
  end

  defp target(%{"type" => "create", "signingKey" => key}), do: key
  defp target(operation), do: get_in(operation, ["verificationMethods", "atproto"])
  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
