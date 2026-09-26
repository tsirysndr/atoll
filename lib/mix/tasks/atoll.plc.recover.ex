defmodule Mix.Tasks.Atoll.Plc.Recover do
  use Mix.Task
  @shortdoc "Stage or resume a signed recovery restoring the current local identity"
  @moduledoc """
      mix atoll.plc.recover stage DID SIGNED_OPERATION_JSON_FILE
      mix atoll.plc.recover stage-key DID SIGNED_OPERATION_JSON_FILE PRIVATE_KEY_JSON_FILE EXPECTED_CURRENT_DID_KEY
      mix atoll.plc.recover status DID
      mix atoll.plc.recover resume DID OPERATION_CID

  The signed recovery must match the local service, handle and retained PLC
  authority. stage-key permits a supplied repository key; stage preserves it. Completion revokes sessions, app passwords,
  and pending account challenges. Account password and email are unchanged.
  """
  def run(args) do
    action =
      case args do
        ["stage", "did:plc:" <> _ = did, path] ->
          operation = read_operation!(path)
          fn opts -> Atoll.Identity.PLC.LocalRecovery.stage(did, operation, opts) end

        ["stage-key", "did:plc:" <> _ = did, path, key_path, expected] ->
          operation = read_operation!(path)
          key = read_key!(key_path)

          fn opts ->
            Atoll.Identity.PLC.LocalRecovery.stage_key(did, operation, expected, key, opts)
          end

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

  defp read_key!(path) do
    with {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= 4096 <-
           File.open(path, [:read, :binary], &IO.binread(&1, 4097)),
         {:ok, %Jason.OrderedObject{values: fields}} when length(fields) == 2 <-
           Jason.decode(bytes, objects: :ordered_objects),
         %{"curve" => curve, "privateKey" => private} when is_binary(private) <- Map.new(fields),
         curve when curve in [:k256, :p256] <- %{"k256" => :k256, "p256" => :p256}[curve],
         {:ok, <<_::binary-size(32)>> = private} <- Base.decode64(private),
         {:ok, key} <- Atoll.SigningKey.from_private(curve, private) do
      key
    else
      _ -> Mix.raise("Invalid or unreadable recovery private-key file (maximum 4 KiB).")
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
