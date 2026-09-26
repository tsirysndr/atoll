defmodule Mix.Tasks.Atoll.Plc.ReconcileNullified do
  use Mix.Task
  @shortdoc "Close pending PLC work explicitly nullified by fresh verified directory history"
  @moduledoc """
      mix atoll.plc.reconcile_nullified DID PENDING_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID

  Retains signed journal history, erases pending private custody, and releases only
  this operation's handle reservations. Requires fresh verified nullification.
  Does not submit operations, reconcile the local identity, or revoke credentials.
  Active, absent-from-history, or locally completed operations cannot be closed.
  """
  def run(args) do
    case args do
      ["did:plc:" <> _ = did, cid, expected] ->
        Mix.Task.run("app.start")
        opts = Application.get_env(:atoll, :plc_submission_options, [])

        case Atoll.Identity.PLC.NullifiedUpdates.reconcile(did, cid, expected, opts) do
          {:ok, result} ->
            Mix.shell().info(Jason.encode!(result))

          _ ->
            Mix.raise(
              "PLC reconciliation failed; verify the pending CID, expected directory head, and explicit nullification in directory history."
            )
        end

      _ ->
        Mix.raise(
          "Usage: mix atoll.plc.reconcile_nullified DID PENDING_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID"
        )
    end
  end
end
