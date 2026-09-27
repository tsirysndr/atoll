defmodule Mix.Tasks.Atoll.Plc.ReconcileDirectoryKey do
  use Mix.Task
  @shortdoc "Complete an accepted administrative directory-key update at a reviewed PLC head"
  @moduledoc """
      mix atoll.plc.reconcile_directory_key DID PENDING_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID

  Requires verified surviving history and the requested signing key at the current
  directory head. Completes the local journal, audit and identity notification.
  Does not POST to PLC, change local private custody, or change account availability.
  """
  def run(args) do
    case args do
      ["did:plc:" <> _ = did, cid, expected] ->
        Mix.Task.run("app.start")
        opts = Application.get_env(:atoll, :plc_submission_options, []) |> Keyword.take([:plug])

        case Atoll.Accounts.AdminSigningKey.reconcile(did, cid, expected, opts) do
          {:ok, result} ->
            Mix.shell().info(Jason.encode!(result))

          _ ->
            Mix.raise(
              "Directory key reconciliation failed; verify the reviewed head, surviving operation and current signing key."
            )
        end

      _ ->
        Mix.raise(
          "Usage: mix atoll.plc.reconcile_directory_key DID PENDING_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID"
        )
    end
  end
end
