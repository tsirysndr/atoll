defmodule Mix.Tasks.Atoll.Keys.Rewrap do
  use Mix.Task
  @shortdoc "Rewraps one bounded page of stored private keys with the active encryption key"
  @moduledoc """
  Uses the configured active and previous encryption keys; never accepts keys as arguments.

      mix atoll.keys.rewrap --limit 100
      mix atoll.keys.rewrap --limit 100 --after did:plc:example

  Prints counts and an optional DID cursor. Repeat with that cursor until absent.
  Each page commits atomically. A failed page must be repaired and retried; do not skip it.
  """
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [limit: [:integer, :keep], after: [:string, :keep]])

    limit = Keyword.get(opts, :limit, 100)
    cursor = opts[:after]

    unless positional == [] and invalid == [] and
             length(opts) == length(Enum.uniq(Keyword.keys(opts))) and is_integer(limit) and
             limit in 1..100 and (is_nil(cursor) or Atoll.Syntax.did?(cursor)),
           do: Mix.raise("Usage: mix atoll.keys.rewrap [--limit 1..100] [--after DID]")

    Mix.Task.run("app.start")

    case Atoll.KeyRewrap.batch(limit, cursor) do
      {:ok, result} -> Mix.shell().info(Jason.encode!(result))
      {:error, _} -> Mix.raise("Key rewrap failed; no changes in this page were committed.")
    end
  end
end
