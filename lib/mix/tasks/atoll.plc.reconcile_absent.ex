defmodule Mix.Tasks.Atoll.Plc.ReconcileAbsent do
  use Mix.Task
  @shortdoc "Close pending PLC work absent from fresh verified directory history"
  @moduledoc """
      mix atoll.plc.reconcile_absent DID PENDING_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID

  Closes journals the directory never recorded, including tombstoned or otherwise
  incompatible directory identities, after operator review of the current head.
  Retains signed journal history, erases pending private custody, and releases only
  this operation's handle reservations. Operations still submittable at the current
  head, explicitly nullified operations, and recovery journals are rejected.
  """
  def run(args) do
    case args do
      ["did:plc:" <> _ = did, cid, expected] ->
        Mix.Task.run("app.start")
        opts = Application.get_env(:atoll, :plc_submission_options, [])

        case Atoll.Identity.PLC.AbsentUpdates.reconcile(did, cid, expected, opts) do
          {:ok, result} ->
            Mix.shell().info(Jason.encode!(result))

          _ ->
            Mix.raise(
              "Absent PLC reconciliation failed; verify the pending CID, expected directory head, and that the operation is absent and no longer submittable."
            )
        end

      _ ->
        Mix.raise(
          "Usage: mix atoll.plc.reconcile_absent DID PENDING_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID"
        )
    end
  end
end
