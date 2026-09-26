defmodule Mix.Tasks.Atoll.Plc.InstallRotationKey do
  use Mix.Task
  @shortdoc "Installs a PLC rotation key after fresh directory verification"
  @moduledoc """
      mix atoll.plc.install_rotation_key DID PRIVATE_KEY_JSON_FILE

  File: {"curve":"k256"|"p256","privateKey":"BASE64_32_BYTES"}.
  Reads at most 4096 bytes. Does not print the key or submit a directory operation.
  Identical installs are idempotent. To explicitly replace an installed key, append
  --replace EXPECTED_CURRENT_DID_KEY. Fresh directory authorization is required.
  """
  def run([did, path]), do: perform(did, path, nil)
  def run([did, path, "--replace", expected]), do: perform(did, path, expected)
  def run(_), do: usage!()

  defp perform(did, path, expected) do
    unless Regex.match?(~r/\Adid:plc:[a-z2-7]{24}\z/, did), do: usage!()

    if expected && not match?({:ok, _}, Atoll.Multikey.from_did_key(expected)), do: usage!()

    with {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= 4096 <-
           File.open(path, [:read, :binary], &IO.binread(&1, 4097)),
         {:ok, %{"curve" => curve, "privateKey" => private} = data}
         when map_size(data) == 2 and is_binary(private) <-
           Jason.decode(bytes),
         curve when curve in [:k256, :p256] <- %{"k256" => :k256, "p256" => :p256}[curve],
         {:ok, <<_::binary-size(32)>> = private} <- Base.decode64(private),
         {:ok, key} <- Atoll.SigningKey.from_private(curve, private) do
      Mix.Task.run("app.start")

      opts = Application.get_env(:atoll, :plc_submission_options, [])

      result =
        if expected,
          do: Atoll.Identity.PLC.RotationKeys.replace(did, expected, key, opts),
          else: Atoll.Identity.PLC.RotationKeys.install(did, key, opts)

      case result do
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

  defp usage!,
    do:
      Mix.raise(
        "Usage: mix atoll.plc.install_rotation_key DID PRIVATE_KEY_JSON_FILE [--replace EXPECTED_CURRENT_DID_KEY]"
      )
end
