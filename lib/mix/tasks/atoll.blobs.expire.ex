defmodule Mix.Tasks.Atoll.Blobs.Expire do
  use Mix.Task
  @shortdoc "Expires one audited batch of old, unreferenced blob ownership"
  @moduledoc """
      mix atoll.blobs.expire --limit 100 --grace-seconds 86400

  Limit: 1–1000 (default 100). Grace: 3600–31536000 seconds (default 86400).
  Removes expired staging ownership and queues byte cleanup in one transaction
  with its operator audit record. Referenced blobs remain owned. This task does
  not delete S3 or PostgreSQL bytes; the separate collector handles queued work.
  """
  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [limit: [:integer, :keep], grace_seconds: [:integer, :keep]]
      )

    limit = Keyword.get(opts, :limit, 100)
    grace = Keyword.get(opts, :grace_seconds, 86_400)

    unless positional == [] and invalid == [] and
             length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
             limit in 1..1000 and grace in 3600..31_536_000,
           do:
             Mix.raise(
               "Usage: mix atoll.blobs.expire [--limit 1..1000] [--grace-seconds 3600..31536000]"
             )

    Mix.Task.run("app.start")

    case Atoll.Blobs.Cleanup.expire_staged(limit: limit, grace_seconds: grace, actor: "operator") do
      {:ok, count} -> Mix.shell().info(Jason.encode!(%{expired: count, limit: limit}))
      {:error, _} -> Mix.raise("Staged blob expiration failed; no batch was committed.")
    end
  end
end
