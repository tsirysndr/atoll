defmodule Atoll.Moderation.Audit do
  @moduledoc "Append-only application history of supported operator decisions. Not an authorization API."
  import Ecto.Query
  alias Atoll.{Repo, Syntax}
  alias Atoll.Moderation.AuditEntry

  @doc "Records an operator repository-key transition with public metadata only."
  def repository_key!(
        before_head,
        after_head,
        expected,
        result,
        operation \\ "atoll.keys.rotateWeb"
      ) do
    state = fn head ->
      {:ok, key} = Atoll.Multikey.to_did_key(head.curve, head.public_key)
      %{key: key, commit: Atoll.CID.to_base32(head.head)}
    end

    insert!(
      operation,
      before_head.did,
      %{kind: "repositorySigningKey", did: before_head.did},
      %{expectedKey: expected, result: Atom.to_string(result)},
      state.(before_head),
      state.(after_head),
      "operator"
    )
  end

  @doc "Records a locally reconciled recovery with public scope and credential counts."
  def recovery!(row, counts) do
    insert!(
      "atoll.plc.recover",
      row.did,
      %{kind: "plcRecovery", did: row.did},
      %{operationCid: row.cid, nullifiedCids: row.recovery_nullified_cids},
      %{
        directoryHead: row.recovery_expected_head,
        repositoryKey: row.expected_signing_key,
        authorityKey: row.expected_authority_key,
        authorityWasAbsent:
          not is_nil(row.authority_public_key) and is_nil(row.expected_authority_key)
      },
      %{
        directoryHead: row.cid,
        repositoryKey:
          if(row.signing_public_key,
            do: elem(Atoll.Multikey.to_did_key(row.signing_curve, row.signing_public_key), 1)
          ),
        authorityKey:
          if(row.authority_public_key,
            do: elem(Atoll.Multikey.to_did_key(row.authority_curve, row.authority_public_key), 1)
          ),
        revokedSessions: counts.sessions,
        revokedAppPasswords: counts.app_passwords
      },
      "operator"
    )
  end

  @doc "Records why an unsubmitted signup reservation was selected for operator deletion."
  def signup_cleanup!(row, cutoff, actor) do
    insert!(
      "atoll.accounts.cleanupSignups",
      row.did,
      %{kind: "signup", did: row.did},
      %{genesisCid: row.cid, cutoff: DateTime.to_iso8601(cutoff)},
      %{reserved: true, submissionStarted: false},
      %{reserved: false},
      actor
    )
  end

  @doc "Records an operator custom-domain signup reservation without credentials or email."
  def signup_reservation!(did, handle, genesis_cid) do
    insert!(
      "atoll.accounts.reserveCustomSignup",
      did,
      %{kind: "signup", did: did},
      %{handle: handle, genesisCid: genesis_cid},
      %{reserved: false},
      %{reserved: true},
      "operator"
    )
  end

  @doc "Records closure of directory-nullified work without erasing signed history."
  def nullified_update!(row, head, reservations) do
    insert!(
      "atoll.plc.reconcileNullified",
      row.did,
      %{kind: "plcUpdate", did: row.did},
      %{operationCid: row.cid, observedHead: head},
      %{
        pending: true,
        repositoryCustody: not is_nil(row.signing_envelope),
        authorityCustody: not is_nil(row.authority_envelope)
      },
      %{pending: false, nullified: true, releasedHandleReservations: reservations},
      "operator"
    )
  end

  @doc "Records explicit erasure of superseded signup custody, without secret material."
  def signup_key_retirement!(registration, installed) do
    {:ok, old} =
      Atoll.Multikey.to_did_key(registration.rotation_curve, registration.rotation_public_key)

    {:ok, current} = Atoll.Multikey.to_did_key(installed.curve, installed.public_key)

    insert!(
      "atoll.plc.retireSignupKey",
      registration.did,
      %{kind: "plcSignupKey", did: registration.did},
      %{
        genesisCid: registration.cid,
        installedKey: current,
        installedOperationCid: installed.verified_cid
      },
      %{key: old, retained: true},
      %{key: old, retained: false},
      "operator"
    )
  end

  @doc "Records an ordinary PLC authority-key replacement without private material."
  def authority_rotation!(did, cid, expected, replacement) do
    insert!(
      "atoll.plc.rotateAuthority",
      did,
      %{kind: "plcRotationKey", did: did},
      %{operationCid: cid, expectedKey: expected},
      %{key: expected},
      %{key: replacement},
      "operator"
    )
  end

  @doc "Records local operator key custody changes using public metadata only."
  def rotation_key!(did, expected, observed_cid, before_key, after_key, result) do
    insert!(
      if(expected == :absent,
        do: "atoll.plc.installRotationKey",
        else: "atoll.plc.replaceRotationKey"
      ),
      did,
      %{kind: "plcRotationKey", did: did},
      %{
        expectedKey: if(expected == :absent, do: nil, else: expected),
        observedOperationCid: observed_cid,
        result: Atom.to_string(result)
      },
      rotation_key_state(before_key),
      rotation_key_state(after_key),
      "operator"
    )
  end

  defp rotation_key_state(nil), do: %{installed: false}

  defp rotation_key_state(row) do
    {:ok, key} = Atoll.Multikey.to_did_key(row.curve, row.public_key)
    %{installed: true, key: key, verifiedOperationCid: row.verified_cid}
  end

  @doc "Records operator invite actions; server-wide actions have no account DID."
  def invite_codes!(operation, did, requested, before_state, after_state) do
    insert!(operation, did, %{kind: "inviteCodes"}, requested, before_state, after_state)
  end

  @doc "Tracks email attempts without retaining addresses, subjects or message bodies."
  def email_delivery!(params, id, before_status, after_status) do
    did = params["recipientDid"]

    insert!(
      "com.atproto.admin.sendEmail",
      did,
      %{"$type" => "com.atproto.admin.defs#repoRef", "did" => did},
      params |> Map.take(["recipientDid", "senderDid", "comment"]) |> Map.put("messageId", id),
      %{status: before_status},
      %{status: after_status}
    )
  end

  @doc "Append inside the moderation transaction, after taking the event lock. Never records credentials."
  def append!(did, subject, requested, before_state, after_state) do
    insert!(
      "com.atproto.admin.updateSubjectStatus",
      did,
      subject,
      Map.take(requested, ["takedown", "deactivated"]),
      before_state,
      after_state
    )
  end

  @doc "Records an operator email change without storing any email challenge or credential."
  def email_change!(before_profile, after_profile, account) do
    unless before_profile.did == after_profile.did,
      do: raise(ArgumentError, "audit account mismatch")

    did = after_profile.did

    insert!(
      "com.atproto.admin.updateAccountEmail",
      did,
      %{"$type" => "com.atproto.admin.defs#repoRef", "did" => did},
      %{"account" => account, "email" => after_profile.email},
      email_state(before_profile),
      email_state(after_profile)
    )
  end

  @doc "Records password replacement and revocation counts, never passwords or their hashes."
  def password_change!(did, sessions, apps) do
    insert!(
      "com.atproto.admin.updateAccountPassword",
      did,
      %{"$type" => "com.atproto.admin.defs#repoRef", "did" => did},
      %{"did" => did},
      %{sessions: sessions, appPasswords: apps},
      %{sessions: 0, appPasswords: 0, passwordChanged: true}
    )
  end

  @doc "Records account invitation controls, including no-ops and changes to private reasons."
  def invite_control!(before_profile, after_profile, params) do
    unless before_profile.did == after_profile.did,
      do: raise(ArgumentError, "audit account mismatch")

    operation =
      if after_profile.invites_disabled,
        do: "com.atproto.admin.disableAccountInvites",
        else: "com.atproto.admin.enableAccountInvites"

    did = after_profile.did

    insert!(
      operation,
      did,
      %{"$type" => "com.atproto.admin.defs#repoRef", "did" => did},
      Map.take(params, ["account", "note"]),
      invite_state(before_profile),
      invite_state(after_profile)
    )
  end

  defp invite_state(profile) do
    %{
      invitesDisabled: profile.invites_disabled,
      inviteNote: profile.invite_control_note,
      invitesUpdatedAt:
        profile.invites_updated_at && DateTime.to_iso8601(profile.invites_updated_at)
    }
  end

  @doc "Records operator deletion without retaining account credentials or private profile data."
  def account_deletion!(head, actor \\ "admin") do
    insert!(
      "com.atproto.admin.deleteAccount",
      head.did,
      %{"$type" => "com.atproto.admin.defs#repoRef", "did" => head.did},
      %{"did" => head.did},
      %{availability: Atom.to_string(head.status)},
      %{availability: "deleted"},
      actor
    )
  end

  defp email_state(profile) do
    %{
      email: profile.email,
      emailAuthFactor: profile.email_auth_factor,
      emailConfirmedAt:
        profile.email_confirmed_at && DateTime.to_iso8601(profile.email_confirmed_at)
    }
  end

  defp insert!(operation, did, subject, requested, before_state, after_state, actor \\ "admin") do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "moderation audit requires a transaction")

    Atoll.Repositories.Events.lock!()

    Repo.insert!(
      %AuditEntry{
        did: did,
        subject: subject,
        actor: actor,
        operation: operation,
        requested: requested,
        before_state: before_state,
        after_state: after_state,
        time: DateTime.utc_now()
      },
      log: false
    )
  end

  @doc "Operator-only keyset pagination. Includes private reasons; never expose without authorization."
  def list(limit \\ 100, after_id \\ 0, did \\ nil)

  def list(limit, after_id, did)
      when is_integer(limit) and limit in 1..1000 and is_integer(after_id) and
             after_id >= 0 and after_id <= 9_223_372_036_854_775_807 do
    if is_nil(did) or Syntax.did?(did) do
      query = from e in AuditEntry, where: e.id > ^after_id, order_by: e.id, limit: ^(limit + 1)
      query = if did, do: from(e in query, where: e.did == ^did), else: query
      rows = Repo.all(query, log: false)
      page = Enum.take(rows, limit)
      result = %{entries: Enum.map(page, &entry/1)}

      result =
        if length(rows) > limit,
          do: Map.put(result, :cursor, Integer.to_string(List.last(page).id)),
          else: result

      {:ok, result}
    else
      {:error, :invalid_audit_query}
    end
  end

  def list(_, _, _), do: {:error, :invalid_audit_query}

  defp entry(row) do
    %{
      id: Integer.to_string(row.id),
      did: row.did,
      subject: row.subject,
      actor: row.actor,
      operation: row.operation,
      requested: row.requested,
      before: row.before_state,
      after: row.after_state,
      time: DateTime.to_iso8601(row.time)
    }
  end
end
