defmodule Mix.Tasks.Atoll.Plc.RetireSignupKey do
  use Mix.Task
  @shortdoc "Erase superseded signup private custody after completed PLC key reconciliation"
  @moduledoc """
      mix atoll.plc.retire_signup_key DID EXPECTED_GENESIS_CID EXPECTED_INSTALLED_DID_KEY

  Irreversibly erases the historical signup key envelope, preserving signed genesis
  and public metadata. Requires completed signup, readable repository and installed
  authority keys, a completed authority update, and no pending PLC update. Keep any
  desired offline recovery backup before invoking. Does not revoke directory keys,
  erase backups, or change the currently installed authority. Repeating is safe.
  """
  def run(args) do
    case args do
      ["did:plc:" <> _ = did, genesis, expected] ->
        Mix.Task.run("app.start")

        case Atoll.Identity.PLC.SignupKeyRetirement.retire(did, genesis, expected) do
          {:ok, result} ->
            Mix.shell().info(Jason.encode!(result))

          {:error, _} ->
            Mix.raise(
              "Signup key retirement failed; check expected public metadata, readable installed keys, completed signup/update, and pending work."
            )
        end

      _ ->
        Mix.raise(
          "Usage: mix atoll.plc.retire_signup_key DID EXPECTED_GENESIS_CID EXPECTED_INSTALLED_DID_KEY"
        )
    end
  end
end
