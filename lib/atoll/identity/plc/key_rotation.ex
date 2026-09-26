defmodule Atoll.Identity.PLC.KeyRotation do
  @moduledoc "Operator-only ordinary PLC repository-key rotation with durable staging and resumable completion."
  import Ecto.Query
  alias Atoll.{CBOR, KeyVault, Multikey, Repo, Repositories, SigningKey}
  alias Atoll.Accounts.{Profile, Signup}
  alias Atoll.Identity.{Handle, HandleReservation, Observation}
  alias Atoll.Identity.PLC.{Client, Operation, PendingSigningKeys, Registrations, Update, Updates}
  alias Atoll.Repositories.{Events, Head}

  def status(did) do
    case Repo.one(
           from u in Update,
             where: u.did == ^did and is_nil(u.completed_at) and not is_nil(u.signing_public_key)
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
         %Profile{} = profile <- Repo.get(Profile, did),
         observation = Repo.get(Observation, did),
         {:ok, %{entries: audit, state: state}} <-
           Client.fetch_audit(did, Keyword.take(opts, [:plug])),
         {:ok, successor} <- Operation.successor(state.operation),
         :ok <- compatible(successor, expected, profile.handle),
         :ok <- forward(did, profile.handle, opts) do
      Repo.transaction(fn ->
        head = lock!(did)
        fence!(head, expected, profile.handle, observation)
        key = SigningKey.generate(curve)
        {:ok, public} = Multikey.to_did_key(curve, key.public)
        rotation = unwrap!(Registrations.rotation_key(did))

        operation =
          unwrap!(
            Operation.sign(
              put_in(successor, ["verificationMethods", "atproto"], public),
              rotation
            )
          )

        unwrap!(PendingSigningKeys.stage(did, audit, operation, expected, key))
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
         %Update{signing_public_key: public} = row when is_binary(public) <-
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

  defp preflight(row, handle, observation) do
    Repo.transaction(fn ->
      head = lock!(row.did)
      current = Repo.get_by!(Update, did: row.did, cid: row.cid)

      expected =
        if current.completed_at, do: public_key(current), else: current.expected_signing_key

      fence!(head, expected, handle, observation)
      unless current.operation == row.operation, do: Repo.rollback(:plc_conflict)
      unwrap!(KeyVault.fetch(row.did))
      unless current.completed_at, do: unwrap!(PendingSigningKeys.fetch(row.did, row.cid))
      :ok
    end)
  end

  defp finish(row, handle, observation) do
    Repo.transaction(fn ->
      head = lock!(row.did)

      current =
        Repo.get_by(Update, did: row.did, cid: row.cid) || Repo.rollback(:plc_update_not_found)

      unless current.operation == row.operation and current.confirmed_at,
        do: Repo.rollback(:plc_conflict)

      if current.completed_at do
        fence!(head, public_key(current), handle, Repo.get(Observation, row.did))
        %{did: row.did, cid: row.cid, result: :completed}
      else
        fence!(head, current.expected_signing_key, handle, observation)
        check!(key_only(current, handle))
        key = unwrap!(PendingSigningKeys.fetch(row.did, row.cid))
        Events.append!(:identity, head, %{"handle" => handle})
        updated = unwrap!(Repositories.rotate_signing_key(row.did, key, head.head))

        fingerprint =
          :crypto.hash(
            :sha256,
            CBOR.encode!(%{
              "handle" => handle,
              "claimedHandle" => handle,
              "pds" => AtollWeb.Endpoint.url(),
              "curve" => Atom.to_string(key.curve),
              "key" => %CBOR.Bytes{data: key.public}
            })
          )

        Repo.insert!(%Observation{did: row.did, handle: handle, fingerprint: fingerprint},
          on_conflict: {:replace, [:handle, :fingerprint]},
          conflict_target: [:did]
        )

        Updates.complete!(row.did, row.cid)
        PendingSigningKeys.release!(row.did, row.cid)

        Atoll.Moderation.Audit.repository_key!(
          head,
          updated,
          current.expected_signing_key,
          :rotated,
          "atoll.keys.rotatePlc"
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
         :ok <- compatible(successor, row.expected_signing_key, handle),
         true <-
           Map.delete(row.operation, "sig") ==
             put_in(successor, ["verificationMethods", "atproto"], public_key(row)) do
      :ok
    else
      _ -> {:error, :invalid_key_rotation}
    end
  end

  defp compatible(operation, expected, handle) do
    if get_in(operation, ["verificationMethods", "atproto"]) == expected and
         operation["alsoKnownAs"] == ["at://" <> handle] and
         get_in(operation, ["services", "atproto_pds"]) == %{
           "type" => "AtprotoPersonalDataServer",
           "endpoint" => AtollWeb.Endpoint.url()
         }, do: :ok, else: {:error, :invalid_key_rotation}
  end

  defp fence!(head, expected, handle, observation) do
    unless head.status in [:active, :deactivated], do: Repo.rollback(:repo_inactive)

    unless Multikey.to_did_key(head.curve, head.public_key) == {:ok, expected},
      do: Repo.rollback(:stale_signing_key)

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

  defp public_key(row) do
    {:ok, key} = Multikey.to_did_key(row.signing_curve, row.signing_public_key)
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
