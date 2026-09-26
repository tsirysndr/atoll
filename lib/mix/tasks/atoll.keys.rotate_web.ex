defmodule Mix.Tasks.Atoll.Keys.RotateWeb do
  use Mix.Task
  @shortdoc "Reconcile a did:web repository key after its DID document is updated"
  @moduledoc """
      mix atoll.keys.rotate_web DID PRIVATE_KEY_JSON_FILE EXPECTED_CURRENT_DID_KEY

  File: {"curve":"k256"|"p256","privateKey":"BASE64_32_BYTES"}.
  Update the external DID document first. This command verifies fresh identity and
  handle resolution, then changes the local vault/commit atomically. No PLC writes.
  """
  def run(["did:web:" <> _ = did, path, expected]) do
    with {:ok, _} <- Atoll.Multikey.from_did_key(expected),
         {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= 4096 <-
           File.open(path, [:read, :binary], &IO.binread(&1, 4097)),
         {:ok, %Jason.OrderedObject{values: fields}} when length(fields) == 2 <-
           Jason.decode(bytes, objects: :ordered_objects),
         %{"curve" => curve, "privateKey" => private} when is_binary(private) <- Map.new(fields),
         curve when curve in [:k256, :p256] <- %{"k256" => :k256, "p256" => :p256}[curve],
         {:ok, <<_::binary-size(32)>> = private} <- Base.decode64(private),
         {:ok, key} <- Atoll.SigningKey.from_private(curve, private) do
      Mix.Task.run("app.start")
      opts = Application.get_env(:atoll, :identity_resolution_options, [])

      case Atoll.Identity.WebKeyRotation.rotate(did, expected, key, opts) do
        {:ok, result} ->
          Mix.shell().info(Jason.encode!(result))

        _ ->
          Mix.raise(
            "Key rotation failed; check expected key, DID/handle authority, account state, and vault configuration."
          )
      end
    else
      _ -> Mix.raise("Invalid expected key or unreadable/invalid private-key file.")
    end
  end

  def run(_),
    do:
      Mix.raise(
        "Usage: mix atoll.keys.rotate_web DID PRIVATE_KEY_JSON_FILE EXPECTED_CURRENT_DID_KEY"
      )
end
