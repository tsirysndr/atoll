defmodule Atoll.Identity.PLC.AuthorityRotation do
  @moduledoc "Operator-only ordinary PLC directory-authority key rotation with durable staging and resumable completion."
  import Ecto.Query
  alias Atoll.{KeyVault, Multikey, Repo, SigningKey}
  alias Atoll.Accounts.{Profile, Signup}
  alias Atoll.Identity.{Handle, HandleReservation, Observation}

  alias Atoll.Identity.PLC.{
    Client,
    Operation,
    PendingAuthorityKeys,
    Registrations,
    RotationKeys,
    Update,
    Updates
  }

  alias Atoll.Repositories.{Events, Head}

  def status(did) do
    case Repo.one(
           from u in Update,
             where:
               u.did == ^did and is_nil(u.completed_at) and is_nil(u.nullified_at) and
                 not is_nil(u.authority_public_key)
         ) do
      nil ->
        {:ok, %{did: did, result: :no_pending_rotation}}

      row ->
        {:ok,
         %{
           did: did,
           cid: row.cid,
           key: public_key(row),
           result: :pending,
           confirmed: not is_nil(row.confirmed_at)
         }}
    end
  end

  def stage(did, expected, curve, opts \\ []) do
    with false <- Repo.in_transaction?(),
         true <- curve in [:k256, :p256],
         {:ok, _} <- Multikey.from_did_key(expected),
         %Head{} = prior <- Repo.get(Head, did),
         %Profile{} = profile <- Repo.get(Profile, did),
         observation = Repo.get(Observation, did),
         {:ok, %{entries: audit, state: state}} <-
           Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         {:ok, successor} <- Operation.successor(state.operation),
         :ok <- compatible(successor, prior, profile.handle),
         true <- expected in successor["rotationKeys"],
         :ok <- forward(did, profile.handle, opts) do
      Repo.transaction(fn ->
        head = lock!(did)
        fence!(head, expected, profile.handle, observation, successor)
        key = SigningKey.generate(curve)
        {:ok, public} = Multikey.to_did_key(curve, key.public)
        rotation = unwrap!(Registrations.rotation_key(did))

        operation =
          unwrap!(
            Operation.sign(
              replace_authority(successor, expected, public),
              rotation
            )
          )

        unwrap!(PendingAuthorityKeys.stage(did, audit, operation, expected, key))
        {:ok, cid} = Operation.cid(operation)
        %{did: did, cid: cid, key: public, result: :staged}
      end)
    else
      true -> {:error, :plc_update_inside_transaction}
      false -> {:error, :invalid_key}
      nil -> {:error, :account_not_found}
      error -> error
    end
  end

  def resume(did, cid, opts \\ []) do
    with false <- Repo.in_transaction?(),
         %Update{nullified_at: nil, authority_public_key: public} = row when is_binary(public) <-
           Repo.get_by(Update, did: did, cid: cid),
         %Profile{} = profile <- Repo.get(Profile, did),
         observation = Repo.get(Observation, did),
         :ok <- key_only(row, profile.handle),
         :ok <- forward(did, profile.handle, opts),
         {:ok, %{state: state}} <- Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         true <- not state.tombstoned and state.cid in [row.cid, row.operation["prev"]],
         {:ok, _} <- preflight(row, profile.handle, observation),
         {:ok, _} <- Updates.submit(did, cid, Keyword.take(opts, [:plug])),
         {:ok, %{state: latest}} <- Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         true <- not latest.tombstoned and latest.cid == cid,
         :ok <- forward(did, profile.handle, opts) do
      finish(row, profile.handle, observation)
    else
      true -> {:error, :plc_update_inside_transaction}
      false -> {:error, :plc_conflict}
      nil -> {:error, :plc_update_not_found}
      %Update{} -> {:error, :pending_key_not_found}
      error -> error
    end
  end

  @doc "Reconcile accepted authority rotation after reviewed compatible directory advancement; never submits."
  def reconcile(did, cid, expected_head, opts \\ []) do
    with false <- Repo.in_transaction?(),
         %Update{
           nullified_at: nil,
           authority_public_key: public,
           recovery_expected_head: nil,
           signing_public_key: nil
         } = row
         when is_binary(public) <- Repo.get_by(Update, did: did, cid: cid),
         %Profile{} = profile <- Repo.get(Profile, did),
         observation = Repo.get(Observation, did),
         :ok <- key_only(row, profile.handle),
         {:ok, %{entries: entries, state: state}} <-
           Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         true <- not state.tombstoned and state.cid == expected_head and cid in state.active_cids,
         true <- Enum.any?(entries, &(&1["cid"] == cid and &1["operation"] == row.operation)),
         true <- state.operation["rotationKeys"] == row.operation["rotationKeys"],
         :ok <- forward(did, profile.handle, opts) do
      finish(row, profile.handle, observation, state)
    else
      true -> {:error, :plc_update_inside_transaction}
      {:error, _} = error -> error
      _ -> {:error, :plc_conflict}
    end
  end

  defp preflight(row, handle, observation) do
    Repo.transaction(fn ->
      head = lock!(row.did)
      current = Repo.get_by!(Update, did: row.did, cid: row.cid)
      if current.nullified_at, do: Repo.rollback(:plc_update_nullified)

      expected =
        if current.completed_at, do: public_key(current), else: current.expected_authority_key

      fence!(head, expected, handle, observation, row.operation)
      unless current.operation == row.operation, do: Repo.rollback(:plc_conflict)
      unwrap!(KeyVault.fetch(row.did))
      unless current.completed_at, do: unwrap!(PendingAuthorityKeys.fetch(row.did, row.cid))
      :ok
    end)
  end

  defp finish(row, handle, observation, verified_head \\ nil) do
    Repo.transaction(fn ->
      head = lock!(row.did)

      current =
        Repo.get_by(Update, did: row.did, cid: row.cid) || Repo.rollback(:plc_update_not_found)

      unless is_nil(current.nullified_at) and current.operation == row.operation and
               (current.confirmed_at || verified_head),
             do: Repo.rollback(:plc_conflict)

      if verified_head do
        if current.recovery_expected_head || current.signing_public_key,
          do: Repo.rollback(:invalid_key_workflow)

        check!(compatible(verified_head.operation, head, handle))

        unless verified_head.operation["rotationKeys"] == current.operation["rotationKeys"],
          do: Repo.rollback(:plc_conflict)

        unwrap!(KeyVault.fetch(row.did))

        if is_nil(current.confirmed_at),
          do: current |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now()) |> Repo.update!()
      end

      if current.completed_at do
        fence!(head, public_key(current), handle, observation, current.operation)
        %{did: row.did, cid: row.cid, result: :completed}
      else
        fence!(head, current.expected_authority_key, handle, observation, current.operation)
        check!(key_only(current, handle))
        :ok = RotationKeys.adopt_pending!(row.did, row.cid)
        Updates.complete!(row.did, row.cid)
        PendingAuthorityKeys.release!(row.did, row.cid)

        Atoll.Moderation.Audit.authority_rotation!(
          row.did,
          row.cid,
          current.expected_authority_key,
          public_key(current),
          if(verified_head, do: verified_head.cid)
        )

        %{did: row.did, cid: row.cid, result: :completed}
      end
    end)
  end

  defp key_only(row, handle) do
    with {:ok, cid} <- Operation.cid(row.operation),
         true <- cid == row.cid,
         {:ok, _} <- Operation.verify_update(row.previous, row.operation),
         {:ok, successor} <- Operation.successor(row.previous),
         true <- successor["alsoKnownAs"] == ["at://" <> handle],
         true <- row.expected_authority_key in successor["rotationKeys"],
         false <- public_key(row) in successor["rotationKeys"],
         true <-
           Map.delete(row.operation, "sig") ==
             replace_authority(successor, row.expected_authority_key, public_key(row)) do
      :ok
    else
      _ -> {:error, :invalid_key_rotation}
    end
  end

  defp compatible(operation, head, handle) do
    {:ok, expected} = Multikey.to_did_key(head.curve, head.public_key)

    if get_in(operation, ["verificationMethods", "atproto"]) == expected and
         operation["alsoKnownAs"] == ["at://" <> handle] and
         get_in(operation, ["services", "atproto_pds"]) == %{
           "type" => "AtprotoPersonalDataServer",
           "endpoint" => AtollWeb.Endpoint.url()
         }, do: :ok, else: {:error, :invalid_key_rotation}
  end

  defp fence!(head, expected, handle, observation, operation) do
    unless head.status in [:active, :deactivated], do: Repo.rollback(:repo_inactive)

    authority = unwrap!(Registrations.rotation_key(head.did))

    unless Multikey.to_did_key(authority.curve, authority.public) == {:ok, expected},
      do: Repo.rollback(:stale_rotation_key)

    check!(compatible(operation, head, handle))

    unless match?(%Profile{handle: ^handle}, Repo.get(Profile, head.did)) and
             Repo.get(Observation, head.did) == observation,
           do: Repo.rollback(:stale_identity_refresh)

    if Repo.get_by(HandleReservation, did: head.did), do: Repo.rollback(:plc_update_pending)
  end

  defp forward(did, handle, opts) do
    if Signup.hosted_handle?(handle) or
         Handle.resolve(handle, Keyword.put(opts, :force_refresh, true)) == {:ok, did},
       do: :ok,
       else: {:error, :unverified_handle}
  end

  defp replace_authority(successor, expected, public) do
    Map.update!(successor, "rotationKeys", fn keys ->
      Enum.map(keys, fn key -> if key == expected, do: public, else: key end)
    end)
  end

  defp public_key(row) do
    {:ok, key} = Multikey.to_did_key(row.authority_curve, row.authority_public_key)
    key
  end

  defp lock!(did) do
    Events.lock!()

    Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
      Repo.rollback(:account_not_found)
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
  defp check!(:ok), do: :ok
  defp check!({:error, reason}), do: Repo.rollback(reason)
end
