# Run through mix run --no-start; do not start Atoll's endpoint or workers.
try do
  result =
    case System.argv() do
      ["verify", directory] ->
        Atoll.Blobs.S3Archive.verify!(directory)

      [action, directory] when action in ["backup", "restore"] ->
        storage = Application.fetch_env!(:atoll, :blob_storage)
        :s3 = storage[:backend]
        {:ok, _} = Application.ensure_all_started(:req)

        case action do
          "backup" -> Atoll.Blobs.S3Archive.backup!(directory, storage[:s3])
          "restore" -> Atoll.Blobs.S3Archive.restore!(directory, storage[:s3])
        end

      _ ->
        raise "Usage: mix run --no-start scripts/s3_backup.exs backup|verify|restore DIRECTORY"
    end

  IO.puts("S3 archive operation completed: #{result.count} objects")
rescue
  _ ->
    # Exceptions may include signed requests, credentials or unpublished data.
    IO.puts(
      :stderr,
      "S3 archive operation failed; check arguments, configuration and archive integrity"
    )

    System.halt(1)
end
