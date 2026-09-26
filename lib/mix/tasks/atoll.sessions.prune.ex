defmodule Mix.Tasks.Atoll.Sessions.Prune do
  use Mix.Task
  @shortdoc "Deletes one bounded batch of expired sessions"
  @moduledoc """
  Deletes expired session rows from the configured database.

      mix atoll.sessions.prune
      MIX_ENV=prod mix atoll.sessions.prune --limit 1000

  The default batch limit is 500, with a permitted range of 1–1000. This command
  processes one batch and skips rows locked by other transactions. Run it again
  or schedule recurring invocations to clear a backlog. It never deletes a
  session whose expiration is later than the start of the batch.
  """

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [limit: [:integer, :keep]])
    limit = Keyword.get(opts, :limit, 500)

    unless positional == [] and invalid == [] and length(opts) <= 1 and limit in 1..1000,
      do: Mix.raise("Usage: mix atoll.sessions.prune [--limit 1..1000]")

    Mix.Task.run("app.start")

    case Atoll.Accounts.SessionCleanup.prune_expired(limit) do
      {:ok, count} ->
        Mix.shell().info("Deleted #{count} expired sessions (batch limit #{limit}).")

      {:error, _} ->
        Mix.raise("Expired-session cleanup failed.")
    end
  end
end
