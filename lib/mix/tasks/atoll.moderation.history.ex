defmodule Mix.Tasks.Atoll.Moderation.History do
  use Mix.Task
  @shortdoc "Exports one bounded page of private moderation decision history"
  @moduledoc """
  Reads supported operator decisions from the configured database as JSON.
  Includes subject status, email/password changes, account invitation controls, and deletion.

      mix atoll.moderation.history --limit 100 --after 0
      mix atoll.moderation.history --did did:plc:example

  `--limit` is 1..1000 (default 100); `--after` is an exclusive nonnegative audit
  ID (default 0). A `cursor` is returned when more entries exist. Pass it as
  `--after` for the next page. IDs are JSON strings to retain integer precision.
  This read-only operator task includes private email addresses, moderation references, and retained
  history for deleted accounts. It does not accept or print admin credentials.
  """
  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [limit: [:integer, :keep], after: [:integer, :keep], did: [:string, :keep]]
      )

    limit = Keyword.get(opts, :limit, 100)
    after_id = Keyword.get(opts, :after, 0)
    did = opts[:did]

    unless positional == [] and invalid == [] and
             length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
             is_integer(limit) and limit in 1..1000 and is_integer(after_id) and
             after_id >= 0 and after_id <= 9_223_372_036_854_775_807 and
             (is_nil(did) or Atoll.Syntax.did?(did)),
           do:
             Mix.raise(
               "Usage: mix atoll.moderation.history [--limit 1..1000] [--after ID] [--did DID]"
             )

    Mix.Task.run("app.start")
    {:ok, page} = Atoll.Moderation.Audit.list(limit, after_id, did)
    Mix.shell().info(Jason.encode!(page))
  end
end
