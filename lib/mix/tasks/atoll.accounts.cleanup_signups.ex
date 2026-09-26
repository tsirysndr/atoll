defmodule Mix.Tasks.Atoll.Accounts.CleanupSignups do
  use Mix.Task
  @shortdoc "Preview or delete old signup reservations with no recorded PLC submission"
  @moduledoc """
      mix atoll.accounts.cleanup_signups --older-than-days 7 --limit 100
      mix atoll.accounts.cleanup_signups --older-than-days 7 --limit 100 --apply

  Defaults to dry-run, seven days, and at most 100 accounts. --apply deletes one
  atomic page. Repeat while more=true. Submitted, legacy, confirmed, completed and
  non-deactivated accounts are protected. Invite uses are not refunded. Upgrade
  all writers to the submission-marker implementation before applying cleanup.
  """
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          older_than_days: [:integer, :keep],
          limit: [:integer, :keep],
          apply: [:boolean, :keep]
        ]
      )

    days = Keyword.get(opts, :older_than_days, 7)
    limit = Keyword.get(opts, :limit, 100)

    unless rest == [] and invalid == [] and length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
             is_integer(days) and days in 1..3650 and is_integer(limit) and limit in 1..100,
           do:
             Mix.raise(
               "Usage: mix atoll.accounts.cleanup_signups [--older-than-days 1..3650] [--limit 1..100] [--apply]"
             )

    Mix.Task.run("app.start")

    case Atoll.Accounts.SignupCleanup.batch(days, limit, not Keyword.get(opts, :apply, false)) do
      {:ok, result} ->
        Mix.shell().info(Jason.encode!(result))

      _ ->
        Mix.raise(
          "Signup cleanup failed; the page was rolled back. Retry after resolving database contention."
        )
    end
  end
end
