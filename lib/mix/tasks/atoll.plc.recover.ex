defmodule Mix.Tasks.Atoll.Plc.Recover do
  use Mix.Task
  @shortdoc "Stage or resume a signed recovery restoring the current local identity"
  @moduledoc """
      mix atoll.plc.recover stage DID SIGNED_OPERATION_JSON_FILE
      mix atoll.plc.recover status DID
      mix atoll.plc.recover resume DID OPERATION_CID

  The signed recovery must restore the current local repository key, service,
  handle, and retained PLC authority. Completion revokes sessions, app passwords,
  and pending account challenges. Account password and email are unchanged.
  """
  def run(args) do
    action =
      case args do
        ["stage", "did:plc:" <> _ = did, path] ->
          operation = read_operation!(path)
          fn opts -> Atoll.Identity.PLC.LocalRecovery.stage(did, operation, opts) end

        ["status", "did:plc:" <> _ = did] ->
          fn _ -> Atoll.Identity.PLC.LocalRecovery.status(did) end

        ["resume", "did:plc:" <> _ = did, cid] ->
          fn opts -> Atoll.Identity.PLC.LocalRecovery.resume(did, cid, opts) end

        _ ->
          Mix.raise(
            "Usage: mix atoll.plc.recover stage DID SIGNED_OPERATION_JSON_FILE | status DID | resume DID OPERATION_CID"
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
          "PLC recovery failed; inspect the pending journal and identity authority. Retry the same CID after resolving the failure; never delete an ambiguously submitted operation."
        )
    end
  end

  defp read_operation!(path) do
    with {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= 65_536 <-
           File.open(path, [:read, :binary], &IO.binread(&1, 65_537)),
         {:ok, decoded} <- Jason.decode(bytes, objects: :ordered_objects),
         operation = unique!(decoded, 0),
         :ok <- Atoll.Identity.PLC.Operation.validate_submission(operation) do
      operation
    else
      _ -> Mix.raise("Invalid or unreadable signed recovery file (maximum 64 KiB).")
    end
  catch
    :invalid -> Mix.raise("Invalid or unreadable signed recovery file (maximum 64 KiB).")
  end

  defp unique!(_, depth) when depth > 8, do: throw(:invalid)

  defp unique!(%Jason.OrderedObject{values: pairs}, depth) do
    keys = Enum.map(pairs, &elem(&1, 0))
    unless length(keys) == MapSet.size(MapSet.new(keys)), do: throw(:invalid)
    Map.new(pairs, fn {key, value} -> {key, unique!(value, depth + 1)} end)
  end

  defp unique!(list, depth) when is_list(list), do: Enum.map(list, &unique!(&1, depth + 1))
  defp unique!(value, _), do: value
end
