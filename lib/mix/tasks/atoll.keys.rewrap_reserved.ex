defmodule Mix.Tasks.Atoll.Keys.RewrapReserved do
  use Mix.Task
  @shortdoc "Rewraps one bounded page of reserved signing keys"
  @moduledoc """
  Rewraps reserved keys using configured active and previous master keys.

      mix atoll.keys.rewrap_reserved --limit 100
      mix atoll.keys.rewrap_reserved --limit 100 --after did:key:z...

  Prints counts and an optional public-key cursor. Repeat until no cursor remains.
  A failed page rolls back completely; repair custody and retry without skipping it.
  Run this in addition to `mix atoll.keys.rewrap` before retiring old master keys.
  """
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [limit: [:integer, :keep], after: [:string, :keep]])

    limit = Keyword.get(opts, :limit, 100)
    cursor = opts[:after]

    unless positional == [] and invalid == [] and
             length(opts) == length(Enum.uniq(Keyword.keys(opts))) and is_integer(limit) and
             limit in 1..100 and (is_nil(cursor) or valid_cursor?(cursor)),
           do:
             Mix.raise("Usage: mix atoll.keys.rewrap_reserved [--limit 1..100] [--after DID_KEY]")

    Mix.Task.run("app.start")

    case Atoll.Accounts.SigningKeyReservations.rewrap(limit, cursor) do
      {:ok, result} ->
        Mix.shell().info(Jason.encode!(result))

      {:error, _} ->
        Mix.raise("Reserved key rewrap failed; no changes in this page were committed.")
    end
  end

  defp valid_cursor?(value) when byte_size(value) <= 256,
    do: match?({:ok, %{curve: :k256}}, Atoll.Multikey.from_did_key(value))

  defp valid_cursor?(_), do: false
end
