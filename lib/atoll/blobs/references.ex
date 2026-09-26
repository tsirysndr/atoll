defmodule Atoll.Blobs.References do
  @moduledoc "Internal reference indexing inside the repository mutation transaction. Imports may reference missing blobs."
  import Ecto.Query
  alias Atoll.{CBOR, CID, Repo}
  alias Atoll.Blobs.{Blob, Reference}

  def apply_writes!(did, prepared, rev) do
    paths = Enum.map(prepared, &elem(&1, 1))

    prior =
      Repo.all(from r in Reference, where: r.did == ^did and r.path in ^paths, select: r.cid)

    Repo.delete_all(from r in Reference, where: r.did == ^did and r.path in ^paths)

    for {action, path, _, bytes} <- prepared,
        action != :delete,
        do: insert_record!(did, path, bytes, rev, false)

    withdraw!(did, prior)
  end

  def import!(did, records, blocks, rev) do
    prior = Repo.all(from r in Reference, where: r.did == ^did, select: r.cid)
    Repo.delete_all(from r in Reference, where: r.did == ^did)
    for {path, cid} <- records, do: insert_record!(did, path, Map.fetch!(blocks, cid), rev, true)
    withdraw!(did, prior)
  end

  defp insert_record!(did, path, bytes, rev, allow_missing) do
    {:ok, value} = CBOR.decode(bytes)
    references = collect(value, %{})

    for {cid, metadata} <- references do
      unless allow_missing do
        Atoll.Blobs.Takedowns.ensure_available!(did, cid)

        case Repo.get_by(Blob, did: did, cid: cid) do
          %Blob{mime_type: mime, size: size}
          when mime == metadata.mime_type and size == metadata.size ->
            :ok

          nil ->
            Repo.rollback(:blob_not_found)

          _ ->
            Repo.rollback(:invalid_blob_metadata)
        end
      end

      Repo.insert!(
        struct!(Reference, Map.merge(metadata, %{did: did, path: path, cid: cid, rev: rev}))
      )
    end
  end

  defp collect(%{"$type" => "blob"} = value, acc) do
    with %{"ref" => %CBOR.Link{cid: cid}, "mimeType" => mime, "size" => size} <- value,
         true <- map_size(value) == 4 and is_integer(size) and size >= 0,
         {:ok, %{codec: :raw}} <- CID.decode(cid),
         {:ok, ^mime} <- Atoll.Blobs.normalize_mime(mime) do
      metadata = %{mime_type: mime, size: size}

      if Map.has_key?(acc, cid) and acc[cid] != metadata,
        do: Repo.rollback(:invalid_blob_metadata)

      Map.put(acc, cid, metadata)
    else
      _ -> Repo.rollback(:invalid_blob_metadata)
    end
  end

  defp collect(%_{}, acc), do: acc
  defp collect(value, acc) when is_map(value), do: Enum.reduce(Map.values(value), acc, &collect/2)
  defp collect(value, acc) when is_list(value), do: Enum.reduce(value, acc, &collect/2)
  defp collect(_, acc), do: acc

  defp withdraw!(did, cids) do
    # Removing ownership and enqueueing byte cleanup are one transaction.
    remaining = from r in Reference, where: r.did == ^did, select: r.cid

    query =
      from b in Blob,
        where: b.did == ^did and b.cid in ^Enum.uniq(cids),
        where: b.cid not in subquery(remaining)

    Atoll.Blobs.Cleanup.enqueue!(Repo.all(query))
    Repo.delete_all(query)
  end
end
