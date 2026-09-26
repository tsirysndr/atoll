defmodule Atoll.Moderation.Audit do
  @moduledoc "Append-only application history of supported operator decisions. Not an authorization API."
  import Ecto.Query
  alias Atoll.{Repo, Syntax}
  alias Atoll.Moderation.AuditEntry

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
  def account_deletion!(head) do
    insert!(
      "com.atproto.admin.deleteAccount",
      head.did,
      %{"$type" => "com.atproto.admin.defs#repoRef", "did" => head.did},
      %{"did" => head.did},
      %{availability: Atom.to_string(head.status)},
      %{availability: "deleted"}
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

  defp insert!(operation, did, subject, requested, before_state, after_state) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "moderation audit requires a transaction")

    Atoll.Repositories.Events.lock!()

    Repo.insert!(
      %AuditEntry{
        did: did,
        subject: subject,
        actor: "admin",
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
