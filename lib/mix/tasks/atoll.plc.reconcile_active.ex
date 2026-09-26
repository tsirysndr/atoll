defmodule Mix.Tasks.Atoll.Plc.ReconcileActive do
  use Mix.Task
  @shortdoc "Reconcile ordinary pending PLC work still present in the verified active history"
  @moduledoc """
      mix atoll.plc.reconcile_active DID PENDING_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID

  Verifies current history and forward handle ownership, then atomically completes
  compatible ordinary updates and their handle reservations. Does not POST to PLC,
  replace signing/authority keys, recover forks, activate accounts, or issue sessions.
  Key-rotation and recovery journals require their dedicated workflows.
  """
  def run(args) do
    case args do
      ["did:plc:" <> _ = did, cid, expected] ->
        Mix.Task.run("app.start")

        opts =
          Keyword.merge(
            Application.get_env(:atoll, :identity_resolution_options, []),
            Application.get_env(:atoll, :plc_submission_options, [])
          )

        case Atoll.Identity.PLC.ActiveUpdates.reconcile(did, cid, expected, opts) do
          {:ok, result} ->
            Mix.shell().info(Jason.encode!(result))

          _ ->
            Mix.raise(
              "Active PLC reconciliation failed; verify the expected head, active history, local identity and pending workflow."
            )
        end

      _ ->
        Mix.raise(
          "Usage: mix atoll.plc.reconcile_active DID PENDING_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID"
        )
    end
  end
end
