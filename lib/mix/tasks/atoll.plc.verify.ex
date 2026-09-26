defmodule Mix.Tasks.Atoll.Plc.Verify do
  use Mix.Task
  @shortdoc "Verifies a bounded PLC audit-log JSON file offline"
  @moduledoc """
      mix atoll.plc.verify did:plc:EXACT_DID audit-log.json

  Verifies the supplied genesis, signatures, CID links, recovery rules and
  nullification flags. Prints summary JSON. Reads at most 8 MiB and accepts up
  to 1000 operations. No database or network access. Directory timestamps and
  log completeness still require an external source of trust.
  """
  @max_bytes 8 * 1024 * 1024

  def run([did, path]) do
    unless Regex.match?(~r/\Adid:plc:[a-z2-7]{24}\z/, did), do: usage!()

    with {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= @max_bytes <-
           File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)),
         {:ok, entries} <- Jason.decode(bytes),
         {:ok, verified} <- Atoll.Identity.PLC.AuditLog.verify(did, entries) do
      Mix.shell().info(
        Jason.encode!(%{
          did: verified.did,
          lastOperationCid: verified.cid,
          tombstoned: verified.tombstoned,
          activeOperations: length(verified.active_cids),
          nullifiedOperations: length(verified.nullified_cids)
        })
      )
    else
      _ ->
        Mix.raise(
          "PLC audit verification failed: unreadable, oversized, malformed, or invalid log."
        )
    end
  end

  def run(_), do: usage!()
  defp usage!, do: Mix.raise("Usage: mix atoll.plc.verify DID AUDIT_LOG_JSON_FILE")
end
