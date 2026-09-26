defmodule Atoll.Moderation.Audit do
  @moduledoc "Append-only application history of operator subject-status decisions. Not an authorization API."
  import Ecto.Query
  alias Atoll.{Repo, Syntax}
  alias Atoll.Moderation.AuditEntry

  @doc "Append inside the moderation transaction, after taking the event lock. Never records credentials."
  def append!(did, subject, requested, before_state, after_state) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "moderation audit requires a transaction")

    Atoll.Repositories.Events.lock!()

    Repo.insert!(
      %AuditEntry{
        did: did,
        subject: subject,
        actor: "admin",
        operation: "com.atproto.admin.updateSubjectStatus",
        requested: Map.take(requested, ["takedown", "deactivated"]),
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
