defmodule Atoll.Identity.PLC.Submission do
  @moduledoc "Full-session submission of signed PLC updates matching this PDS's local account."
  import Ecto.Query
  alias Atoll.{CBOR, KeyVault, Multikey, Repo}
  alias Atoll.Accounts.{Profile, Sessions, Signup}
  alias Atoll.Identity.{Handle, HandleReservation, Observation}
  alias Atoll.Identity.PLC.{Client, Operation, Update, Updates}
  alias Atoll.Repositories.{Events, Head}

  def submit(token, params, opts \\ [])

  def submit(token, %{"operation" => operation} = params, opts)
      when map_size(params) == 1 and is_map(operation) do
    with false <- Repo.in_transaction?(),
         {:ok, head} <- Sessions.authenticate_management(token),
         :ok <- Operation.validate_submission(operation),
         {:ok, cid} <- Operation.cid(operation),
         :ok <- compatible(head, operation),
         :ok <- forward(head.did, operation, opts),
         {:ok, %{entries: audit}} <- Client.fetch_audit(head.did, Keyword.take(opts, [:plug])),
         {:ok, _} <- stage(token, head.did, audit, operation),
         {:ok, _} <- Sessions.authenticate_management(token),
         {:ok, _} <- Updates.submit(head.did, cid, Keyword.take(opts, [:plug])),
         {:ok, %{state: state}} <- Client.fetch_audit(head.did, Keyword.take(opts, [:plug])),
         true <- state.cid == cid,
         :ok <- forward(head.did, operation, opts) do
      finish(token, head.did, cid, operation)
    else
      true -> {:error, :plc_update_inside_transaction}
      false -> {:error, :plc_conflict}
      error -> error
    end
  end

  def submit(_, _, _), do: {:error, :invalid_request}

  defp stage(token, did, audit, operation) do
    Repo.transaction(fn ->
      head = authorize!(token, did)
      check!(compatible(head, operation))
      unwrap!(KeyVault.fetch(did))
      if Repo.get_by(HandleReservation, did: did), do: Repo.rollback(:plc_update_pending)
      journal = unwrap!(Updates.stage(did, audit, operation))
      reject_key_workflow!(Repo.get_by!(Update, did: did, cid: journal.cid))
      journal
    end)
  end

  defp finish(token, did, cid, operation) do
    Repo.transaction(fn ->
      head = authorize!(token, did)
      check!(compatible(head, operation))
      unwrap!(KeyVault.fetch(did))
      if Repo.get_by(HandleReservation, did: did), do: Repo.rollback(:plc_update_pending)
      row = Repo.get_by(Update, did: did, cid: cid) || Repo.rollback(:plc_update_not_found)
      reject_key_workflow!(row)
      unless row.confirmed_at, do: Repo.rollback(:plc_conflict)

      unless row.completed_at do
        handle = Repo.get!(Profile, did).handle

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

        Events.append!(:identity, head, %{"handle" => handle})
        Updates.complete!(did, cid)
      end

      :submitted
    end)
  end

  defp reject_key_workflow!(row) do
    if row.signing_public_key || row.authority_public_key || row.recovery_expected_head,
      do: Repo.rollback(:plc_update_pending)
  end

  defp compatible(head, operation) do
    {:ok, key} = Multikey.to_did_key(head.curve, head.public_key)
    profile = Repo.get(Profile, head.did)

    if ((operation["type"] == "plc_operation" and profile) && is_binary(profile.handle)) and
         get_in(operation, ["verificationMethods", "atproto"]) == key and
         get_in(operation, ["services", "atproto_pds"]) == %{
           "type" => "AtprotoPersonalDataServer",
           "endpoint" => AtollWeb.Endpoint.url()
         } and
         operation["alsoKnownAs"] == ["at://" <> profile.handle],
       do: :ok,
       else: {:error, :invalid_handle_update}
  end

  defp forward(did, operation, opts) do
    ["at://" <> handle] = operation["alsoKnownAs"]

    if Signup.hosted_handle?(handle) or
         Handle.resolve(handle, Keyword.put(opts, :force_refresh, true)) == {:ok, did},
       do: :ok,
       else: {:error, :unverified_handle}
  end

  defp authorize!(token, did) do
    Events.lock!()

    head =
      Repo.one(from h in Head, where: h.did == ^did, lock: "FOR UPDATE") ||
        Repo.rollback(:account_not_found)

    unwrap!(Sessions.authenticate_management(token))
    head
  end

  defp check!(:ok), do: :ok
  defp check!({:error, reason}), do: Repo.rollback(reason)
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
