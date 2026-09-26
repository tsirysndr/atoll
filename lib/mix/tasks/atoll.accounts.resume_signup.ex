defmodule Mix.Tasks.Atoll.Accounts.ResumeSignup do
  use Mix.Task
  @shortdoc "Resume an exact pending PLC signup without issuing login tokens"
  @moduledoc """
      mix atoll.accounts.resume_signup DID EXPECTED_GENESIS_CID

  Trusted operator action: retries the persisted signed genesis, verifies custom
  handle ownership, and completes local activation. No password input, session,
  email or replacement DID is created. Admission may be disabled; this resumes
  an already admitted reservation. Completed retries are read-only and do not
  reactivate a subsequently deactivated account. The owner logs in normally.
  """
  def run(["did:plc:" <> _ = did, expected]) do
    Mix.Task.run("app.start")

    opts =
      Keyword.merge(
        Application.get_env(:atoll, :identity_resolution_options, []),
        Application.get_env(:atoll, :plc_submission_options, [])
      )

    case Atoll.Accounts.Signup.resume_registration(did, expected, opts) do
      {:ok, result} ->
        Mix.shell().info(Jason.encode!(result))

      _ ->
        Mix.raise(
          "Signup resume failed; check the exact genesis CID, account state, current handle ownership, directory and vault configuration. Retain the reservation for retry."
        )
    end
  end

  def run(_), do: Mix.raise("Usage: mix atoll.accounts.resume_signup DID EXPECTED_GENESIS_CID")
end
