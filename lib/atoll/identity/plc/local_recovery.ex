defmodule Atoll.Identity.PLC.LocalRecovery do
  @moduledoc "Operator recovery of the current local identity using an externally signed PLC fork."
  import Ecto.Query
  alias Atoll.{CBOR, KeyVault, Multikey, Repo}
  alias Atoll.Accounts.{Profile, Signup}
  alias Atoll.Identity.{Handle, HandleReservation, Observation}
  alias Atoll.Identity.PLC.{Client, Operation, Recoveries, Registrations, Update, Updates}
  alias Atoll.Repositories.{Events, Head}

  def status(did) do
    case Repo.one(
           from u in Update,
             where:
               u.did == ^did and is_nil(u.completed_at) and not is_nil(u.recovery_expected_head)
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

  def resume(did, cid, opts \\ []) do
    with false <- Repo.in_transaction?(),
         %Update{recovery_expected_head: expected} = row when is_binary(expected) <-
           Repo.get_by(Update, did: did, cid: cid),
         %Profile{} = profile <- Repo.get(Profile, did),
         observation = Repo.get(Observation, did),
         :ok <- forward(did, profile.handle, opts),
         {:ok, _} <- preflight(row, profile.handle, observation),
         {:ok, _} <- Recoveries.submit(did, cid, Keyword.take(opts, [:plug])),
         {:ok, %{state: state}} <- Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         true <- not state.tombstoned and state.cid == cid,
         :ok <- forward(did, profile.handle, opts) do
      Repo.transaction(fn ->
        head = lock!(did)

        current =
          Repo.get_by(Update, did: did, cid: cid) || Repo.rollback(:plc_recovery_not_found)

        unless current.operation == row.operation and current.confirmed_at,
          do: Repo.rollback(:plc_conflict)

        fence!(
          head,
          current.operation,
          profile.handle,
          if(current.completed_at, do: Repo.get(Observation, did), else: observation)
        )

        unless current.completed_at do
          counts = Atoll.Accounts.CredentialRevocation.revoke!(did)

          fingerprint =
            :crypto.hash(
              :sha256,
              CBOR.encode!(%{
                "handle" => profile.handle,
                "claimedHandle" => profile.handle,
                "pds" => AtollWeb.Endpoint.url(),
                "curve" => Atom.to_string(head.curve),
                "key" => %CBOR.Bytes{data: head.public_key}
              })
            )

          Repo.insert!(%Observation{did: did, handle: profile.handle, fingerprint: fingerprint},
            on_conflict: {:replace, [:handle, :fingerprint]},
            conflict_target: [:did]
          )

          Events.append!(:identity, head, %{"handle" => profile.handle})
          Updates.complete!(did, cid)
          Atoll.Moderation.Audit.recovery!(current, counts)
        end

        %{did: did, cid: cid, result: :completed}
      end)
    else
      true -> {:error, :plc_update_inside_transaction}
      false -> {:error, :plc_conflict}
      nil -> {:error, :plc_recovery_not_found}
      %Update{} -> {:error, :plc_recovery_not_found}
      error -> error
    end
  end

  defp preflight(row, handle, observation) do
    Repo.transaction(fn ->
      head = lock!(row.did)

      if row.signing_public_key || row.authority_public_key,
        do: Repo.rollback(:unsupported_recovery_key_change)

      fence!(head, row.operation, handle, observation)
      :ok
    end)
  end

  defp fence!(head, operation, handle, observation) do
    unless head.status in [:active, :deactivated], do: Repo.rollback(:repo_inactive)
    check!(Operation.validate_submission(operation))
    {:ok, key} = Multikey.to_did_key(head.curve, head.public_key)
    authority = unwrap!(Registrations.rotation_key(head.did))
    {:ok, authority_id} = Multikey.to_did_key(authority.curve, authority.public)

    unless get_in(operation, ["verificationMethods", "atproto"]) == key and
             get_in(operation, ["services", "atproto_pds"]) == %{
               "type" => "AtprotoPersonalDataServer",
               "endpoint" => AtollWeb.Endpoint.url()
             } and
             operation["alsoKnownAs"] == ["at://" <> handle] and
             authority_id in operation["rotationKeys"],
           do: Repo.rollback(:invalid_local_recovery)

    unwrap!(KeyVault.fetch(head.did))

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
