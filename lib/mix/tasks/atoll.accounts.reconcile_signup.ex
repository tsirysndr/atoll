defmodule Mix.Tasks.Atoll.Accounts.ReconcileSignup do
  use Mix.Task
  @shortdoc "Activate a pending signup against an exact verified compatible PLC directory head"
  @moduledoc """
      mix atoll.accounts.reconcile_signup DID EXPECTED_GENESIS_CID EXPECTED_DIRECTORY_HEAD_CID

  Fetches verified directory history and activates only if the current identity
  authorizes the retained keys and matches the local handle/PDS. No PLC POST,
  replacement identity, session or email is created. Pending identity work must
  be reconciled separately. Completed retries report local status without mutation.
  """
  def run(["did:plc:" <> _ = did, genesis, head]) do
    Mix.Task.run("app.start")

    opts =
      Keyword.merge(
        Application.get_env(:atoll, :identity_resolution_options, []),
        Application.get_env(:atoll, :plc_submission_options, [])
      )

    case Atoll.Accounts.Signup.reconcile_registration(did, genesis, head, opts) do
      {:ok, result} ->
        Mix.shell().info(Jason.encode!(result))

      _ ->
        Mix.raise(
          "Signup reconciliation failed; check expected CIDs, verified current identity, retained keys, handle ownership and pending identity work. No replacement identity was submitted."
        )
    end
  end

  def run(_),
    do:
      Mix.raise(
        "Usage: mix atoll.accounts.reconcile_signup DID EXPECTED_GENESIS_CID EXPECTED_DIRECTORY_HEAD_CID"
      )
end
