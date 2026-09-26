defmodule Mix.Tasks.Atoll.Blocks.Prune do
  use Mix.Task
  @shortdoc "Deletes one bounded batch of unreferenced repository blocks"
  @moduledoc """
  Collects old DAG-CBOR blocks with no current or historical repository ownership.

      mix atoll.blocks.prune --limit 500 --grace-seconds 86400

  Limit: 1–1000 (default 500). Grace: 3600–31536000 seconds (default 86400).
  Raw blob bytes use the separate blob cleanup queue. Revision history is retained.
  Only one batch runs; schedule repeated invocations to clear a backlog. The task
  fails without deleting anything if lock or statement deadlines are exceeded.
  """
  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [limit: [:integer, :keep], grace_seconds: [:integer, :keep]]
      )

    limit = Keyword.get(opts, :limit, 500)
    grace = Keyword.get(opts, :grace_seconds, 86_400)

    unless positional == [] and invalid == [] and length(Keyword.get_values(opts, :limit)) <= 1 and
             length(Keyword.get_values(opts, :grace_seconds)) <= 1 and limit in 1..1000 and
             grace in 3600..31_536_000,
           do:
             Mix.raise(
               "Usage: mix atoll.blocks.prune [--limit 1..1000] [--grace-seconds 3600..31536000]"
             )

    Mix.Task.run("app.start")

    case Atoll.Storage.Cleanup.prune(limit: limit, grace_seconds: grace) do
      {:ok, count} ->
        Mix.shell().info(
          "Deleted #{count} unreferenced repository blocks (batch limit #{limit})."
        )

      {:error, _} ->
        Mix.raise("Repository block cleanup failed or is busy; retry later.")
    end
  end
end
