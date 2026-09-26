defmodule Mix.Tasks.Atoll.Keys.RotatePlc do
  use Mix.Task
  @shortdoc "Stage or resume an ordinary PLC repository signing-key rotation"
  @moduledoc """
      mix atoll.keys.rotate_plc stage DID EXPECTED_CURRENT_DID_KEY k256|p256
      mix atoll.keys.rotate_plc resume DID OPERATION_CID
      mix atoll.keys.rotate_plc reconcile DID OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID
      mix atoll.keys.rotate_plc status DID

  Stage generates and encrypts a replacement key and prints the operation CID.
  Resume submits that exact operation and reconciles local publication. Retry
  resume with the same CID after errors. Requires retained PLC rotation authority.
  Reconcile completes accepted rotation after compatible directory advancement,
  using fresh verified history and the exact reviewed head without another POST.
  """
  def run(args) do
    action =
      case args do
        ["stage", "did:plc:" <> _ = did, expected, curve] when curve in ["k256", "p256"] ->
          fn opts ->
            Atoll.Identity.PLC.KeyRotation.stage(
              did,
              expected,
              if(curve == "k256", do: :k256, else: :p256),
              opts
            )
          end

        ["status", "did:plc:" <> _ = did] ->
          fn _ -> Atoll.Identity.PLC.KeyRotation.status(did) end

        ["resume", "did:plc:" <> _ = did, cid] ->
          fn opts -> Atoll.Identity.PLC.KeyRotation.resume(did, cid, opts) end

        ["reconcile", "did:plc:" <> _ = did, cid, expected] ->
          fn opts -> Atoll.Identity.PLC.KeyRotation.reconcile(did, cid, expected, opts) end

        _ ->
          Mix.raise(
            "Usage: mix atoll.keys.rotate_plc stage DID EXPECTED_CURRENT_DID_KEY k256|p256 | resume DID OPERATION_CID | reconcile DID OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID | status DID"
          )
      end

    Mix.Task.run("app.start")

    opts =
      Keyword.merge(
        Application.get_env(:atoll, :identity_resolution_options, []),
        Application.get_env(:atoll, :plc_submission_options, [])
      )

    case action.(opts) do
      {:ok, result} ->
        Mix.shell().info(Jason.encode!(result))

      _ ->
        Mix.raise(
          "PLC key rotation failed; inspect public journal state and retry the same staged CID. Check authority, expected key, account state, and vault configuration."
        )
    end
  end
end
