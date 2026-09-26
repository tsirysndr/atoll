defmodule Atoll.Identity.PLC.RecoveryPlan do
  @moduledoc """
  Bounded preflight of a signed recovery fork against verified PLC audit evidence.

  This is not authorization or submission. Directory timestamps and completeness
  are trusted, and a successful preview does not reserve the recovery window.
  The directory decides acceptance using its receipt time and intervening updates.
  """
  alias Atoll.Identity.PLC.{AuditLog, Client, Operation}
  @window_seconds 72 * 60 * 60

  def from_directory(did, operation, opts \\ []) do
    if Atoll.Repo.in_transaction?() do
      {:error, :plc_update_inside_transaction}
    else
      with {:ok, %{entries: audit}} <- Client.fetch_audit(did, Keyword.take(opts, [:plug])),
           do: preview(did, audit, operation)
    end
  end

  def preview(did, entries, operation, now \\ DateTime.utc_now())

  def preview(did, entries, operation, %DateTime{} = now)
      when is_list(entries) and length(entries) in 1..999 and is_map(operation) do
    with {:ok, state} <- AuditLog.verify(did, entries),
         {:ok, cid} <- Operation.cid(operation),
         previous when is_binary(previous) <- operation["prev"],
         index when is_integer(index) <- Enum.find_index(state.active_cids, &(&1 == previous)),
         [_ | _] = removed <- Enum.drop(state.active_cids, index + 1),
         false <- Enum.any?(entries, &(&1["cid"] == cid)),
         previous_entry = Enum.find(entries, &(&1["cid"] == previous)),
         first_removed = Enum.find(entries, &(&1["cid"] == hd(removed))),
         {:ok, signer} <- Operation.verify_update(previous_entry["operation"], operation),
         {:ok, started_at, 0} <- DateTime.from_iso8601(first_removed["createdAt"]),
         deadline = DateTime.add(started_at, @window_seconds, :second),
         candidate = %{
           "did" => did,
           "cid" => cid,
           "operation" => operation,
           "nullified" => false,
           "createdAt" => DateTime.to_iso8601(now)
         },
         hypothetical = mark_nullified(entries, removed) ++ [candidate],
         {:ok, verified} <- AuditLog.verify(did, hypothetical),
         true <- verified.cid == cid do
      {:ok,
       %{
         did: did,
         cid: cid,
         previous: previous,
         expected_head: state.cid,
         signer: signer,
         nullified_cids: removed,
         valid_until: deadline,
         tombstoned: verified.tombstoned
       }}
    else
      _ -> {:error, :invalid_plc_recovery}
    end
  end

  def preview(_, _, _, _), do: {:error, :invalid_plc_recovery}

  defp mark_nullified(entries, removed) do
    removed = MapSet.new(removed)

    Enum.map(entries, fn entry ->
      if MapSet.member?(removed, entry["cid"]), do: Map.put(entry, "nullified", true), else: entry
    end)
  end
end
