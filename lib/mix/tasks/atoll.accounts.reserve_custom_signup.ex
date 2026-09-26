defmodule Mix.Tasks.Atoll.Accounts.ReserveCustomSignup do
  use Mix.Task
  @shortdoc "Reserve a fresh PLC DID for a custom-domain signup without directory publication"
  @moduledoc """
      mix atoll.accounts.reserve_custom_signup /secure/signup.json

  Requires ATOLL_SIGNUP_ENABLED=true and ATOLL_CUSTOM_DOMAIN_SIGNUP_ENABLED=true.
  The file contains createAccount fields: handle, password, optional email,
  recoveryKey and inviteCode. It is bounded to 4 KiB. Protect this file as it
  contains the account password. Output is public DID and DNS/HTTPS setup details.
  Publish the printed forward claim, then submit the same fields to createAccount.
  Reservation consumes an invite use if supplied and retains the pending account
  across retries. No PLC request, session or email is issued by this command.
  """
  def run([path]) do
    params = read!(path)
    Mix.Task.run("app.start")

    case Atoll.Accounts.Signup.reserve_custom(params) do
      {:ok, result} ->
        Mix.shell().info(Jason.encode!(result))

      _ ->
        Mix.raise(
          "Custom signup reservation failed; check signup settings, handle, credentials, invite, and vault configuration."
        )
    end
  end

  def run(_), do: Mix.raise("Usage: mix atoll.accounts.reserve_custom_signup /secure/signup.json")

  defp read!(path) do
    with {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= 4096 <-
           File.open(path, [:read, :binary], &IO.binread(&1, 4097)),
         {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(bytes, objects: :ordered_objects),
         true <- length(pairs) == MapSet.size(MapSet.new(Enum.map(pairs, &elem(&1, 0)))) do
      Map.new(pairs)
    else
      _ ->
        Mix.raise("Invalid or unreadable signup JSON file (maximum 4 KiB, unique object keys).")
    end
  end
end
