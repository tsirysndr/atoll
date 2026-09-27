defmodule Atoll.Blobs.S3Archive do
  @moduledoc """
  Offline, content-verified archives of the current S3 blobs/ namespace.

  Callers must stop writers and lifecycle deletion, protect the local archive
  from concurrent changes, and keep restore targets private throughout recovery.
  This does not snapshot versions, object metadata, database state or KMS keys.
  """
  alias Atoll.{CID, Blobs.S3}
  @max_bytes 5 * 1024 * 1024
  @format "atoll-s3-v1"

  def backup!(directory, config, page_size \\ 100) when page_size in 1..1000 do
    # Refuse an existing path before entering cleanup, even an empty directory.
    File.mkdir!(directory)

    try do
      File.chmod!(directory, 0o700)
      File.mkdir!(Path.join(directory, "blobs"))
      index = Path.join(directory, "index")

      {count, digest} =
        File.open!(index, [:write, :binary, :exclusive], fn io ->
          File.chmod!(index, 0o600)
          copy_pages!(directory, io, config, page_size, nil, "", 0, :crypto.hash_init(:sha256))
        end)

      manifest = %{
        format: @format,
        count: count,
        indexSha256: Base.encode16(digest, case: :lower)
      }

      private_write!(Path.join(directory, "manifest.json"), Jason.encode!(manifest))
      verify!(directory)
    rescue
      error ->
        File.rm_rf!(directory)
        reraise error, __STACKTRACE__
    end
  end

  def verify!(directory) do
    manifest = directory |> Path.join("manifest.json") |> read_regular!(4096) |> Jason.decode!()
    %{"format" => @format, "count" => count, "indexSha256" => expected} = manifest
    true = is_integer(count) and count >= 0
    true = is_binary(expected) and byte_size(expected) == 64
    %{type: :directory} = File.lstat!(directory)
    %{type: :directory} = File.lstat!(Path.join(directory, "blobs"))
    %{type: :regular, size: size} = File.lstat!(Path.join(directory, "index"))
    true = size == count * 60

    {actual_count, digest} = walk!(directory, fn _, _ -> :ok end)
    true = actual_count == count
    true = Base.encode16(digest, case: :lower) == expected
    %{count: count}
  end

  def restore!(directory, config) do
    # Validate every local object before making any target changes.
    result = verify!(directory)
    {:ok, %{objects: [], cursor: nil}} = S3.list(config, 1)

    walk!(directory, fn cid, bytes ->
      :ok = S3.put(cid, bytes, config)
      {:ok, restored} = S3.get(cid, config)
      :ok = CID.verify(cid, restored)
    end)

    result
  end

  defp copy_pages!(directory, io, config, limit, cursor, previous, count, hash) do
    {:ok, page} = S3.list(config, limit, cursor)
    true = is_nil(page.cursor) or (page.cursor != cursor and page.objects != [])

    {previous, count, hash} =
      Enum.reduce(page.objects, {previous, count, hash}, fn object, {previous, count, hash} ->
        "blobs/" <> text = object.key
        cid = raw_cid!(text)
        true = text > previous
        true = object.size <= @max_bytes
        {:ok, bytes} = S3.get(cid, config)
        true = byte_size(bytes) == object.size
        :ok = CID.verify(cid, bytes)
        private_write!(Path.join([directory, "blobs", text]), bytes)
        :ok = IO.binwrite(io, text <> "\n")
        {text, count + 1, :crypto.hash_update(hash, text <> "\n")}
      end)

    if page.cursor do
      copy_pages!(directory, io, config, limit, page.cursor, previous, count, hash)
    else
      {count, :crypto.hash_final(hash)}
    end
  end

  defp walk!(directory, function) do
    File.open!(Path.join(directory, "index"), [:read, :binary], fn io ->
      walk_entries!(io, directory, function, "", 0, :crypto.hash_init(:sha256))
    end)
  end

  defp walk_entries!(io, directory, function, previous, count, hash) do
    case IO.binread(io, 60) do
      :eof ->
        {count, :crypto.hash_final(hash)}

      <<text::binary-size(59), "\n">> = entry ->
        cid = raw_cid!(text)
        true = text > previous
        bytes = read_regular!(Path.join([directory, "blobs", text]), @max_bytes)
        :ok = CID.verify(cid, bytes)
        :ok = function.(cid, bytes)
        walk_entries!(io, directory, function, text, count + 1, :crypto.hash_update(hash, entry))

      _ ->
        raise "Invalid S3 archive index"
    end
  end

  defp raw_cid!(text) do
    {:ok, cid} = CID.from_base32(text)
    {:ok, %{codec: :raw}} = CID.decode(cid)
    cid
  end

  defp read_regular!(path, maximum) do
    %{type: :regular, size: size} = File.lstat!(path)
    true = size <= maximum

    File.open!(path, [:read, :binary], fn io ->
      bytes =
        case IO.binread(io, maximum + 1) do
          :eof -> ""
          bytes when is_binary(bytes) -> bytes
        end

      true = byte_size(bytes) == size
      bytes
    end)
  end

  defp private_write!(path, bytes) do
    File.open!(path, [:write, :binary, :exclusive], fn io ->
      File.chmod!(path, 0o600)
      :ok = IO.binwrite(io, bytes)
    end)
  end
end
