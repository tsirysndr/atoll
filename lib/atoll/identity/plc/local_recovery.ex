defmodule Atoll.Identity.PLC.LocalRecovery do
  @moduledoc "Operator reconciliation of signed PLC recovery with optional repository and authority key restoration."
  import Ecto.Query
  alias Atoll.{CBOR, KeyVault, Multikey, Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{Profile, Signup}
  alias Atoll.Identity.{Handle, HandleReservation, Observation}

  alias Atoll.Identity.PLC.{
    Client,
    Operation,
    PendingSigningKeys,
    PendingAuthorityKeys,
    RotationKeys,
    Recoveries,
    Registrations,
    Update,
    Updates
  }

  alias Atoll.Repositories.{Events, Head}

  def status(did) do
    case Repo.one(
           from u in Update,
             where:
               u.did == ^did and is_nil(u.completed_at) and is_nil(u.nullified_at) and
                 not is_nil(u.recovery_expected_head)
         ) do
      nil ->
        {:ok, %{did: did, result: :no_pending_recovery}}

      row ->
        {:ok,
         %{
           did: did,
           cid: row.cid,
           result: :pending,
           confirmed: not is_nil(row.confirmed_at),
           expected_head: row.recovery_expected_head,
           valid_until: row.recovery_deadline,
           nullified_cids: row.recovery_nullified_cids
         }}
    end
  end

  def stage(did, operation, opts \\ []) do
    with false <- Repo.in_transaction?(),
         :ok <- Operation.validate_submission(operation),
         %Profile{} = profile <- Repo.get(Profile, did),
         observation = Repo.get(Observation, did),
         {:ok, %{entries: audit}} <- Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         :ok <- forward(did, profile.handle, opts) do
      Repo.transaction(fn ->
        head = lock!(did)
        fence!(head, operation, profile.handle, observation)
        unwrap!(Recoveries.stage(did, audit, operation))
      end)
    else
      true -> {:error, :plc_update_inside_transaction}
      nil -> {:error, :account_not_found}
      error -> error
    end
  end

  def stage_key(did, operation, expected, key, opts \\ []),
    do: stage_keys(did, operation, {expected, key}, nil, opts)

  def stage_authority(did, operation, expected, key, opts \\ []),
    do: stage_keys(did, operation, nil, {expected, key}, opts)

  def stage_keys(did, operation, repository, authority, opts \\ []) do
    with false <- Repo.in_transaction?(),
         :ok <- Operation.validate_submission(operation),
         true <- not is_nil(repository) or not is_nil(authority),
         {:ok, repository_context} <- validate_key(repository),
         {:ok, authority_context} <- validate_authority(authority),
         %Profile{} = profile <- Repo.get(Profile, did),
         observation = Repo.get(Observation, did),
         {:ok, %{entries: audit}} <- Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         :ok <- forward(did, profile.handle, opts) do
      Repo.transaction(fn ->
        head = lock!(did)

        fence!(
          head,
          operation,
          profile.handle,
          observation,
          repository_context,
          authority_context
        )

        if repository do
          {expected, key} = repository
          unwrap!(PendingSigningKeys.stage_recovery(did, audit, operation, expected, key))
        end

        if authority do
          {expected, key} = authority
          unwrap!(PendingAuthorityKeys.stage_recovery(did, audit, operation, expected, key))
        end

        {:ok, cid} = Operation.cid(operation)

        %{
          did: did,
          cid: cid,
          repository_key: context_public(repository_context),
          authority_key: context_public(authority_context),
          result: :staged
        }
      end)
    else
      true -> {:error, :plc_update_inside_transaction}
      false -> {:error, :invalid_key}
      nil -> {:error, :account_not_found}
      error -> error
    end
  end

  defp validate_authority({:absent, %SigningKey{} = key}) do
    with {:ok, public} <- Multikey.to_did_key(key.curve, key.public),
         {:ok, _} <- validate_key({public, key}),
         do: {:ok, {:absent, public}}
  end

  defp validate_authority(value), do: validate_key(value)

  defp validate_key(nil), do: {:ok, nil}

  defp validate_key({expected, %SigningKey{} = key}) do
    with {:ok, _} <- Multikey.from_did_key(expected),
         {:ok, derived} <- SigningKey.from_private(key.curve, key.private),
         true <- derived.public == key.public,
         {:ok, public} <- Multikey.to_did_key(key.curve, key.public) do
      {:ok, {expected, public}}
    else
      _ -> {:error, :invalid_key}
    end
  end

  defp validate_key(_), do: {:error, :invalid_key}
  defp context_public(nil), do: nil
  defp context_public({_, public}), do: public

  def resume(did, cid, opts \\ []) do
    with false <- Repo.in_transaction?(),
         %Update{nullified_at: nil, recovery_expected_head: expected} = row
         when is_binary(expected) <-
           Repo.get_by(Update, did: did, cid: cid),
         %Profile{} = profile <- Repo.get(Profile, did),
         observation = Repo.get(Observation, did),
         :ok <- forward(did, profile.handle, opts),
         {:ok, _} <- preflight(row, profile.handle, observation),
         {:ok, _} <- Recoveries.submit(did, cid, Keyword.take(opts, [:plug])),
         {:ok, %{state: state}} <- Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         true <- not state.tombstoned and state.cid == cid,
         :ok <- forward(did, profile.handle, opts) do
      finish(row, profile.handle, observation)
    else
      true -> {:error, :plc_update_inside_transaction}
      false -> {:error, :plc_conflict}
      nil -> {:error, :plc_recovery_not_found}
      %Update{} -> {:error, :plc_recovery_not_found}
      error -> error
    end
  end

  @doc "Reconcile a previously accepted recovery after compatible directory advancement; never submits."
  def reconcile(did, cid, expected_head, opts \\ []) do
    with false <- Repo.in_transaction?(),
         %Update{nullified_at: nil, recovery_expected_head: expected} = row
         when is_binary(expected) <- Repo.get_by(Update, did: did, cid: cid),
         %Profile{} = profile <- Repo.get(Profile, did),
         observation = Repo.get(Observation, did),
         {:ok, %{entries: entries, state: state}} <-
           Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         true <- not state.tombstoned and state.cid == expected_head and cid in state.active_cids,
         {before, [accepted | _]} <- Enum.split_while(entries, &(&1["cid"] != cid)),
         true <- accepted["operation"] == row.operation,
         :ok <-
           Client.verify_recovery_acceptance(before ++ [accepted], cid, %{
             expected_head: row.recovery_expected_head,
             valid_until: row.recovery_deadline,
             nullified_cids: row.recovery_nullified_cids
           }),
         true <- state.operation["rotationKeys"] == row.operation["rotationKeys"],
         :ok <- forward(did, profile.handle, opts) do
      finish(row, profile.handle, observation, state)
    else
      true -> {:error, :plc_update_inside_transaction}
      {:error, _} = error -> error
      _ -> {:error, :plc_recovery_conflict}
    end
  end

  defp finish(row, handle, observation, verified_head \\ nil) do
    did = row.did
    cid = row.cid

    Repo.transaction(fn ->
      head = lock!(did)

      current =
        Repo.get_by(Update, did: did, cid: cid) || Repo.rollback(:plc_recovery_not_found)

      unless is_nil(current.nullified_at) and current.operation == row.operation and
               (current.confirmed_at || verified_head),
             do: Repo.rollback(:plc_conflict)

      if verified_head do
        unless current.previous == row.previous and
                 current.recovery_expected_head == row.recovery_expected_head and
                 current.recovery_deadline == row.recovery_deadline and
                 current.recovery_nullified_cids == row.recovery_nullified_cids and
                 verified_head.operation["rotationKeys"] == current.operation["rotationKeys"],
               do: Repo.rollback(:plc_recovery_conflict)

        fence!(
          head,
          verified_head.operation,
          handle,
          if(current.completed_at, do: Repo.get(Observation, did), else: observation),
          key_context!(current),
          authority_context!(current)
        )

        if is_nil(current.confirmed_at),
          do: current |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now()) |> Repo.update!()
      end

      fence!(
        head,
        current.operation,
        handle,
        if(current.completed_at, do: Repo.get(Observation, did), else: observation),
        key_context!(current),
        authority_context!(current)
      )

      unless current.completed_at do
        counts = Atoll.Accounts.CredentialRevocation.revoke!(did)
        Events.append!(:identity, head, %{"handle" => handle})
        if current.authority_public_key, do: RotationKeys.restore_pending!(did, cid)

        updated =
          if current.signing_public_key do
            key = unwrap!(PendingSigningKeys.fetch(did, cid))
            unwrap!(Repositories.recover_signing_key(did, key, head.head))
          else
            head
          end

        fingerprint =
          :crypto.hash(
            :sha256,
            CBOR.encode!(%{
              "handle" => handle,
              "claimedHandle" => handle,
              "pds" => AtollWeb.Endpoint.url(),
              "curve" => Atom.to_string(updated.curve),
              "key" => %CBOR.Bytes{data: updated.public_key}
            })
          )

        Repo.insert!(%Observation{did: did, handle: handle, fingerprint: fingerprint},
          on_conflict: {:replace, [:handle, :fingerprint]},
          conflict_target: [:did]
        )

        Updates.complete!(did, cid)
        if current.signing_public_key, do: PendingSigningKeys.release!(did, cid)
        if current.authority_public_key, do: PendingAuthorityKeys.release!(did, cid)

        Atoll.Moderation.Audit.recovery!(
          current,
          counts,
          if(verified_head, do: verified_head.cid)
        )
      end

      %{did: did, cid: cid, result: :completed}
    end)
  end

  defp preflight(row, handle, observation) do
    Repo.transaction(fn ->
      head = lock!(row.did)

      fence!(head, row.operation, handle, observation, key_context!(row), authority_context!(row))
      :ok
    end)
  end

  defp key_context!(row) do
    if row.signing_public_key && is_nil(row.completed_at) do
      key = unwrap!(PendingSigningKeys.fetch(row.did, row.cid))
      {:ok, public} = Multikey.to_did_key(key.curve, key.public)
      {row.expected_signing_key, public}
    end
  end

  defp authority_context!(row) do
    if row.authority_public_key && is_nil(row.completed_at) do
      key = unwrap!(PendingAuthorityKeys.fetch(row.did, row.cid))
      {:ok, public} = Multikey.to_did_key(key.curve, key.public)
      {row.expected_authority_key || :absent, public}
    end
  end

  defp fence!(head, operation, handle, observation, key_context \\ nil, authority_context \\ nil) do
    unless head.status in [:active, :deactivated], do: Repo.rollback(:repo_inactive)
    check!(Operation.validate_submission(operation))
    {:ok, current_key} = Multikey.to_did_key(head.curve, head.public_key)

    key =
      case key_context do
        nil ->
          unwrap!(KeyVault.fetch(head.did))
          current_key

        {expected, replacement} ->
          unless current_key == expected, do: Repo.rollback(:stale_signing_key)
          replacement
      end

    authority_id =
      case authority_context do
        nil ->
          authority = unwrap!(Registrations.rotation_key(head.did))
          unwrap!(Multikey.to_did_key(authority.curve, authority.public))

        {:absent, replacement} ->
          unless RotationKeys.public_key(head.did) == {:error, :key_not_found},
            do: Repo.rollback(:stale_rotation_key)

          replacement

        {expected, replacement} ->
          unless RotationKeys.public_key(head.did) == {:ok, expected},
            do: Repo.rollback(:stale_rotation_key)

          replacement
      end

    unless get_in(operation, ["verificationMethods", "atproto"]) == key and
             get_in(operation, ["services", "atproto_pds"]) == %{
               "type" => "AtprotoPersonalDataServer",
               "endpoint" => AtollWeb.Endpoint.url()
             } and
             operation["alsoKnownAs"] == ["at://" <> handle] and
             authority_id in operation["rotationKeys"],
           do: Repo.rollback(:invalid_local_recovery)

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

  defp lock!(did) do
    Events.lock!()

    Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
      Repo.rollback(:account_not_found)
  end

  defp check!(:ok), do: :ok
  defp check!({:error, reason}), do: Repo.rollback(reason)
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
