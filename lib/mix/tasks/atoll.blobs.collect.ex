defmodule Mix.Tasks.Atoll.Blobs.Collect do
  use Mix.Task
  @shortdoc "Collects one audited batch of queued, unowned blob bytes"
  @moduledoc """
      mix atoll.blobs.collect --limit 10

  Limit: 1–1000 (default 10). Rechecks ownership before each deletion. Records
  batch intent before processing and per-item outcomes in their local transactions.
  Earlier items can remain committed on failure. S3 deletion cannot roll back;
  an unfinished attempt may include a remote deletion whose local queue job remains.
  Inspect operator history before retrying. Failed S3 requests remain queued.
  """
  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [limit: [:integer, :keep]])
    limit = Keyword.get(opts, :limit, 10)

    unless positional == [] and invalid == [] and length(opts) <= 1 and limit in 1..1000,
      do: Mix.raise("Usage: mix atoll.blobs.collect [--limit 1..1000]")

    Mix.Task.run("app.start")

    case Atoll.Blobs.Cleanup.collect(limit: limit, actor: "operator") do
      {:ok, counts} ->
        Mix.shell().info(Jason.encode!(counts))

        if counts.failed > 0,
          do:
            Mix.raise("Some blob deletions failed and remain queued; inspect collection history.")

      {:error, _} ->
        Mix.raise("Blob collection stopped; inspect history and queue state before retrying.")
    end
  rescue
    _ in [Exqlite.Error, Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError] ->
      Mix.raise(
        "Blob collection stopped; earlier items or remote deletions may have completed. Inspect history and queue state before retrying."
      )
  end
end
