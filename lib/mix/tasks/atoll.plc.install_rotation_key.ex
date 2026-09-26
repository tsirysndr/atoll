defmodule Mix.Tasks.Atoll.Plc.InstallRotationKey do
  use Mix.Task
  @shortdoc "Installs a PLC rotation key after fresh directory verification"
  @moduledoc """
      mix atoll.plc.install_rotation_key DID PRIVATE_KEY_JSON_FILE

  File: {"curve":"k256"|"p256","privateKey":"BASE64_32_BYTES"}.
  Reads at most 4096 bytes. Does not print the key or submit a directory operation.
  Existing installed keys cannot be replaced; identical installs are idempotent.
  """
  def run([did, path]) do
    unless Regex.match?(~r/\Adid:plc:[a-z2-7]{24}\z/, did), do: usage!()

    with {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= 4096 <-
           File.open(path, [:read, :binary], &IO.binread(&1, 4097)),
         {:ok, %{"curve" => curve, "privateKey" => private} = data}
         when map_size(data) == 2 and is_binary(private) <-
           Jason.decode(bytes),
         curve when curve in [:k256, :p256] <- %{"k256" => :k256, "p256" => :p256}[curve],
         {:ok, <<_::binary-size(32)>> = private} <- Base.decode64(private),
         {:ok, key} <- Atoll.SigningKey.from_private(curve, private) do
      Mix.Task.run("app.start")

      case Atoll.Identity.PLC.RotationKeys.install(
             did,
             key,
             Application.get_env(:atoll, :plc_submission_options, [])
           ) do
        {:ok, result} ->
          Mix.shell().info(Jason.encode!(%{did: did, result: result}))

        _ ->
          Mix.raise(
            "PLC rotation key installation failed; check account, authority, pending updates, and encryption configuration."
          )
      end
    else
      _ -> Mix.raise("Unreadable or invalid private-key file.")
    end
  end

  def run(_), do: usage!()

  defp usage!,
    do: Mix.raise("Usage: mix atoll.plc.install_rotation_key DID PRIVATE_KEY_JSON_FILE")
end
