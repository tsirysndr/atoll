defmodule Mix.Tasks.Atoll.Events.Prune do
  use Mix.Task
  @shortdoc "Prunes one expired event prefix and advances the durable replay boundary"
  @moduledoc """
      mix atoll.events.prune --limit 1000 --retention-seconds 604800

  Explicitly deletes at most 1000 events older than the retention period, stopping
  at the first newer event. Default retention is seven days; minimum one hour.
  Does not prune repository revisions or blocks. Prints deleted count and cursor
  floor. Subscribers behind this floor receive OutdatedCursor information.
  """
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [limit: [:integer, :keep], retention_seconds: [:integer, :keep]]
      )

    limit = Keyword.get(opts, :limit, 1000)
    retention = Keyword.get(opts, :retention_seconds, 604_800)

    unless positional == [] and invalid == [] and
             length(opts) == length(Enum.uniq(Keyword.keys(opts))) and is_integer(limit) and
             limit in 1..1000 and is_integer(retention) and retention in 3600..31_536_000,
           do:
             Mix.raise(
               "Usage: mix atoll.events.prune [--limit 1..1000] [--retention-seconds 3600..31536000]"
             )

    Mix.Task.run("app.start")

    case Atoll.Repositories.EventRetention.prune(limit, retention) do
      {:ok, result} ->
        Mix.shell().info(
          Jason.encode!(%{deleted: result.deleted, cursorFloor: Integer.to_string(result.floor)})
        )

      {:error, _} ->
        Mix.raise("Event retention failed or is busy; no batch changes were committed.")
    end
  end
end
