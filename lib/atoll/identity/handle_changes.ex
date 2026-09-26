defmodule Atoll.Identity.HandleChanges do
  @moduledoc "Authorized staging of handle-only PLC updates with durable name reservations."
  import Ecto.Query
  alias Atoll.{Multikey, Repo, Syntax}
  alias Atoll.Accounts.{Profile, Sessions, Signup}
  alias Atoll.Identity.{Handle, HandleReservation, Resolver}
  alias Atoll.Identity.PLC.{AuditLog, Client, Operation, Registrations, Update, Updates}
  alias Atoll.Repositories.{Events, Head}

  def update(token, params, opts \\ [])

  def update(token, %{"handle" => handle} = params, opts) when map_size(params) == 1 do
    with false <- Repo.in_transaction?(),
         {:ok, head} <- Sessions.authenticate_management(token),
         :ok <- active(head),
         {:ok, handle} <- normalize(handle),
         %Profile{} <- Repo.get(Profile, head.did),
         {:ok, result} <- prepare_update(token, head, handle, opts) do
      case result do
        status when status in [:unchanged, :completed] ->
          {:ok, %{did: head.did, handle: handle}}

        %{cid: cid} ->
          with {:ok, fresh} <- Sessions.authenticate_management(token),
               :ok <- active(fresh),
               {:ok, _} <- Updates.submit(head.did, cid, Keyword.take(opts, [:plug])),
               do: complete(token, cid, opts)
      end
    else
      true -> {:error, :plc_update_inside_transaction}
      nil -> {:error, :account_not_found}
      error -> error
    end
  end

  def update(_, _, _), do: {:error, :invalid_request}

  defp prepare_update(token, %{did: "did:web:" <> _}, handle, opts),
    do: Atoll.Identity.WebHandleChanges.update(token, handle, opts)

  defp prepare_update(token, head, handle, opts) do
    case Repo.get_by(HandleReservation, did: head.did) do
      %{handle: ^handle, cid: cid} -> {:ok, %{cid: cid}}
      %HandleReservation{} -> {:error, :plc_update_pending}
      nil -> new_update(token, head, handle, opts)
    end
  end

  defp new_update(token, head, handle, opts) do
    with {:ok, %{entries: audit, state: state}} <-
           Client.fetch_audit(head.did, Keyword.take(opts, [:plug])),
         :ok <- forward_claim(handle, head.did, opts),
         {:ok, successor} <- Operation.successor(state.operation) do
      unsigned = Map.put(successor, "alsoKnownAs", ["at://" <> handle])

      with :ok <- handle_only(state, unsigned, handle, head) do
        if state.operation["alsoKnownAs"] == ["at://" <> handle] and
             match?(%Profile{handle: ^handle}, Repo.get(Profile, head.did)) do
          Repo.transaction(fn ->
            Events.lock!()

            current =
              Repo.one(from h in Head, where: h.did == ^head.did, lock: "FOR UPDATE") ||
                Repo.rollback(:account_not_found)

            unwrap!(Sessions.authenticate_management(token))
            check!(active(current))
            check!(handle_only(state, unsigned, handle, current))

            unless match?(%Profile{handle: ^handle}, Repo.get(Profile, head.did)) and
                     is_nil(Repo.get_by(HandleReservation, did: head.did)),
                   do: Repo.rollback(:plc_update_pending)

            :unchanged
          end)
        else
          with {:ok, rotation} <- Registrations.rotation_key(head.did),
               {:ok, operation} <- Operation.sign(unsigned, rotation),
               do: stage(token, handle, audit, operation, opts)
        end
      end
    end
  end

  @doc "Checks current names and pending reservations; mutations must hold the Events lock."
  def claimed?(handle) do
    Repo.exists?(from p in Profile, where: p.handle == ^handle) or
      Repo.exists?(from r in HandleReservation, where: r.handle == ^handle)
  end

  @doc """
  Stage an already signed handle-only operation for a full-session owner.
  Audit evidence and the operation are internal workflow inputs, not HTTP parameters.
  Keeps the current profile and hosted resolution unchanged until a later completion.
  """
  def stage(token, handle, audit, operation, opts \\ []) do
    with false <- Repo.in_transaction?(),
         {:ok, head} <- Sessions.authenticate_management(token),
         :ok <- active(head),
         {:ok, handle} <- normalize(handle),
         {:ok, state} <- AuditLog.verify(head.did, audit),
         :ok <- handle_only(state, operation, handle, head),
         :ok <- forward_claim(handle, head.did, opts) do
      Repo.transaction(fn ->
        Events.lock!()

        current =
          Repo.one(from h in Head, where: h.did == ^head.did, lock: "FOR UPDATE") ||
            Repo.rollback(:account_not_found)

        unwrap!(Sessions.authenticate_management(token))
        check!(active(current))
        check!(handle_only(state, operation, handle, current))
        profile = Repo.get(Profile, head.did) || Repo.rollback(:account_not_found)

        unless profile.handle == handle or not claimed?(handle),
          do: own_reservation!(handle, head.did)

        journal = unwrap!(Updates.stage(head.did, audit, operation))
        if journal.completed, do: Repo.rollback(:plc_update_completed)

        case Repo.get_by(HandleReservation, did: head.did) do
          nil -> Repo.insert!(%HandleReservation{handle: handle, did: head.did, cid: journal.cid})
          %{handle: ^handle, cid: cid} when cid == journal.cid -> :ok
          _ -> Repo.rollback(:plc_update_pending)
        end

        journal
      end)
    else
      true -> {:error, :plc_update_inside_transaction}
      error -> error
    end
  end

  defp own_reservation!(handle, did) do
    case {Repo.get_by(Profile, handle: handle), Repo.get(HandleReservation, handle)} do
      {nil, %{did: ^did}} -> :ok
      _ -> Repo.rollback(:handle_not_available)
    end
  end

  @doc "Complete a confirmed handle update only after a fresh verified directory-head check."
  def complete(token, cid, opts \\ []) do
    with false <- Repo.in_transaction?(),
         {:ok, head} <- Sessions.authenticate_management(token),
         :ok <- active(head),
         %Update{} = row <- Repo.get_by(Update, did: head.did, cid: cid),
         true <- not is_nil(row.confirmed_at),
         ["at://" <> handle] <- row.operation["alsoKnownAs"],
         {:ok, %{state: state}} <- Client.fetch_audit(head.did, Keyword.take(opts, [:plug])),
         true <- state.cid == cid,
         :ok <- forward_claim(handle, head.did, opts) do
      Repo.transaction(fn ->
        Events.lock!()

        current =
          Repo.one(from h in Head, where: h.did == ^head.did, lock: "FOR UPDATE") ||
            Repo.rollback(:account_not_found)

        unwrap!(Sessions.authenticate_management(token))
        check!(active(current))
        {:ok, prior_cid} = Operation.cid(row.previous)

        check!(
          handle_only(
            %{tombstoned: false, operation: row.previous, cid: prior_cid},
            row.operation,
            handle,
            current
          )
        )

        journal =
          Repo.get_by(Update, did: head.did, cid: cid) || Repo.rollback(:plc_update_not_found)

        profile = Repo.get(Profile, head.did) || Repo.rollback(:account_not_found)

        if journal.completed_at && profile.handle != handle, do: Repo.rollback(:plc_conflict)

        unless journal.completed_at do
          case Repo.get(HandleReservation, handle) do
            %{did: did, cid: ^cid} when did == head.did -> :ok
            _ -> Repo.rollback(:handle_not_available)
          end

          if Repo.exists?(from p in Profile, where: p.handle == ^handle and p.did != ^head.did),
            do: Repo.rollback(:handle_not_available)

          profile |> Ecto.Changeset.change(handle: handle) |> Repo.update!()

          fingerprint =
            :crypto.hash(
              :sha256,
              Atoll.CBOR.encode!(%{
                "handle" => handle,
                "claimedHandle" => handle,
                "pds" => AtollWeb.Endpoint.url(),
                "curve" => Atom.to_string(current.curve),
                "key" => %Atoll.CBOR.Bytes{data: current.public_key}
              })
            )

          Repo.insert!(
            %Atoll.Identity.Observation{did: head.did, handle: handle, fingerprint: fingerprint},
            on_conflict: {:replace, [:handle, :fingerprint]},
            conflict_target: [:did]
          )

          Events.append!(:identity, current, %{"handle" => handle})
          Updates.complete!(head.did, cid)

          Repo.delete_all(
            from r in HandleReservation, where: r.did == ^head.did and r.cid == ^cid
          )
        end

        %{did: head.did, handle: handle}
      end)
    else
      true -> {:error, :plc_update_inside_transaction}
      nil -> {:error, :plc_update_not_found}
      false -> {:error, :plc_conflict}
      {:error, _} = error -> error
      _ -> {:error, :invalid_handle_update}
    end
  end

  defp normalize(handle) do
    with true <- Syntax.handle?(handle),
         normalized = String.downcase(handle),
         {:ok, _} <- Resolver.resolution_url("did:web:" <> normalized) do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_handle}
    end
  end

  defp forward_claim(handle, did, opts) do
    if Signup.hosted_handle?(handle) or
         Handle.resolve(handle, Keyword.put(opts, :force_refresh, true)) == {:ok, did},
       do: :ok,
       else: {:error, :unverified_handle}
  end

  defp handle_only(%{tombstoned: false, operation: previous, cid: cid}, operation, handle, head)
       when is_map(operation) do
    {:ok, key} = Multikey.to_did_key(head.curve, head.public_key)

    with {:ok, successor} <- Operation.successor(previous),
         true <- successor["prev"] == cid do
      expected = Map.put(successor, "alsoKnownAs", ["at://" <> handle])

      if get_in(successor, ["verificationMethods", "atproto"]) == key and
           get_in(successor, ["services", "atproto_pds", "endpoint"]) == AtollWeb.Endpoint.url() and
           Map.delete(operation, "sig") == expected,
         do: :ok,
         else: {:error, :invalid_handle_update}
    else
      _ -> {:error, :invalid_handle_update}
    end
  end

  defp handle_only(_, _, _, _), do: {:error, :invalid_handle_update}
  defp active(%{status: :active}), do: :ok
  defp active(%{status: status}), do: {:error, {:repo_inactive, status}}
  defp check!(:ok), do: :ok
  defp check!({:error, reason}), do: Repo.rollback(reason)
  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
