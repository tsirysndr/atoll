defmodule Mix.Tasks.Atoll.Blobs.Inventory do
  use Mix.Task
  @shortdoc "Reports one read-only page of S3 blob ownership and untracked objects"
  @moduledoc """
      mix atoll.blobs.inventory --limit 100
      mix atoll.blobs.inventory --limit 100 --cursor TOKEN

  Uses configured S3 storage and ListObjectsV2. Prints JSON objects, counts, and an
  optional continuation cursor. Does not delete objects or modify database state.
  Results are observations, not authorization for deletion during concurrent uploads.
  """
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [limit: [:integer, :keep], cursor: [:string, :keep]])

    limit = Keyword.get(opts, :limit, 100)
    cursor = opts[:cursor]

    unless positional == [] and invalid == [] and
             length(opts) == length(Enum.uniq(Keyword.keys(opts))) and is_integer(limit) and
             limit in 1..1000 and Atoll.Blobs.S3Listing.cursor?(cursor),
           do: Mix.raise("Usage: mix atoll.blobs.inventory [--limit 1..1000] [--cursor TOKEN]")

    Mix.Task.run("app.start")

    case Atoll.Blobs.Inventory.page(limit, cursor) do
      {:ok, page} ->
        Mix.shell().info(Jason.encode!(page))

      {:error, _} ->
        Mix.raise(
          "Blob inventory unavailable or invalid; check S3 configuration and listing permissions."
        )
    end
  end
end
