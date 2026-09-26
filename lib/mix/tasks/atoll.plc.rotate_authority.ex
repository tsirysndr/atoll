defmodule Mix.Tasks.Atoll.Plc.RotateAuthority do
  use Mix.Task
  @shortdoc "Stage or resume an ordinary PLC directory-authority key rotation"
  @moduledoc """
      mix atoll.plc.rotate_authority stage DID EXPECTED_AUTHORITY_DID_KEY k256|p256
      mix atoll.plc.rotate_authority resume DID OPERATION_CID
      mix atoll.plc.rotate_authority reconcile DID OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID
      mix atoll.plc.rotate_authority status DID

  Stage generates and encrypts a replacement key and prints the operation CID.
  Resume submits that exact operation and reconciles local publication. Retry
  resume with the same CID after errors. Requires retained PLC rotation authority.
  Reconcile uses fresh active history without resubmission when the directory has
  advanced compatibly. Requires the exact expected head and unchanged authority list.
  """
  def run(args) do
    action =
      case args do
        ["stage", "did:plc:" <> _ = did, expected, curve] when curve in ["k256", "p256"] ->
          fn opts ->
            Atoll.Identity.PLC.AuthorityRotation.stage(
              did,
              expected,
              if(curve == "k256", do: :k256, else: :p256),
              opts
            )
          end

        ["status", "did:plc:" <> _ = did] ->
          fn _ -> Atoll.Identity.PLC.AuthorityRotation.status(did) end

        ["resume", "did:plc:" <> _ = did, cid] ->
          fn opts -> Atoll.Identity.PLC.AuthorityRotation.resume(did, cid, opts) end

        ["reconcile", "did:plc:" <> _ = did, cid, expected] ->
          fn opts -> Atoll.Identity.PLC.AuthorityRotation.reconcile(did, cid, expected, opts) end

        _ ->
          Mix.raise(
            "Usage: mix atoll.plc.rotate_authority stage DID EXPECTED_AUTHORITY_DID_KEY k256|p256 | resume DID OPERATION_CID | reconcile DID OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID | status DID"
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
