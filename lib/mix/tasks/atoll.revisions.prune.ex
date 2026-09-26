defmodule Mix.Tasks.Atoll.Revisions.Prune do
  use Mix.Task
  @shortdoc "Compacts old revisions while preserving current heads and replay dependencies"
  @moduledoc """
      mix atoll.revisions.prune DID --limit 100 --retention-seconds 604800

  Removes at most 100 old revisions per call. Preserves current heads and revisions
  needed by retained replay events. Default age is seven days; minimum one hour.
  Physical block cleanup is separate. Repeat while dependency indexing is incomplete.
  """
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [limit: [:integer, :keep], retention_seconds: [:integer, :keep]]
      )

    limit = Keyword.get(opts, :limit, 100)
    retention = Keyword.get(opts, :retention_seconds, 604_800)

    unless match?([_], positional) and Atoll.Syntax.did?(hd(positional)) and invalid == [] and
             length(opts) == length(Enum.uniq(Keyword.keys(opts))) and is_integer(limit) and
             limit in 1..100 and is_integer(retention) and retention in 3600..31_536_000,
           do:
             Mix.raise(
               "Usage: mix atoll.revisions.prune DID [--limit 1..100] [--retention-seconds 3600..31536000]"
             )

    Mix.Task.run("app.start")

    case Atoll.Repositories.Compaction.prune(hd(positional), limit, retention) do
      {:ok, result} ->
        Mix.shell().info(Jason.encode!(result))

      {:error, _} ->
        Mix.raise("Revision compaction failed or is busy; no batch changes were committed.")
    end
  end
end
