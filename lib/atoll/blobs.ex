defmodule Atoll.Blobs do
  @moduledoc """
  Internal account-scoped blob staging, not an authorization boundary.

  Bytes are content-addressed in PostgreSQL or S3-compatible object storage. Ownership and
  MIME metadata belong to each repository. All blobs are currently staged:
  none may be served publicly until record-reference tracking is implemented.
  MIME validation checks syntax only, not file contents. The local size limit is
  5 MiB per blob; streaming, quotas, expiration and garbage collection are pending.
  """
  import Ecto.Query
  alias Atoll.{CID, Repo, Repositories, Storage}
  alias Atoll.Blobs.{Blob, S3}
  alias Atoll.Repositories.{Events, Head}
  @max_size 5 * 1024 * 1024

  @doc "Stage bytes for an active hosted repository and return ATProto JSON blob metadata."
  def stage(did, bytes, content_type, opts \\ [])

  def stage(did, bytes, content_type, opts) when is_binary(did) and is_binary(bytes) do
    with :ok <- size(bytes, Keyword.get(opts, :content_length)),
         {:ok, mime} <- mime(content_type),
         {:ok, _} <- Repositories.get_active_head(did),
         cid = CID.create(bytes, :raw),
         {:ok, backend} <- prepare_backend(did, cid, bytes, storage(opts)) do
      Repo.transaction(fn ->
        Events.lock!()
        active_head!(did, "FOR UPDATE")
        if backend == :postgres, do: Storage.put_block(cid, bytes)

        Repo.insert_all(
          Blob,
          [
            %{
              did: did,
              cid: cid,
              backend: backend,
              mime_type: mime,
              size: byte_size(bytes),
              staged_at: DateTime.utc_now()
            }
          ], on_conflict: :nothing, conflict_target: [:did, :cid])

        # The first MIME declaration for this account/CID remains authoritative.
        descriptor(Repo.get_by!(Blob, did: did, cid: cid))
      end)
    end
  end

  def stage(_, _, _, _), do: {:error, :invalid_blob}

  @doc "Internal staged-byte read. Never expose directly as getBlob or listBlobs."
  def get_staged(did, cid, opts \\ [])

  def get_staged(did, cid, opts) when is_binary(did) and is_binary(cid) do
    with {:ok, %{codec: :raw}} <- CID.decode(cid) do
      Repo.transaction(fn ->
        active_head!(did, "FOR SHARE")
        blob = Repo.get_by(Blob, did: did, cid: cid) || Repo.rollback(:blob_not_found)

        with {:ok, bytes} <- read_bytes(blob, storage(opts)),
             :ok <- CID.verify(cid, bytes),
             true <- byte_size(bytes) == blob.size do
          %{blob: descriptor(blob), bytes: bytes}
        else
          _ -> Repo.rollback(:invalid_blob_storage)
        end
      end)
    else
      _ -> {:error, :invalid_blob_cid}
    end
  end

  def get_staged(_, _, _), do: {:error, :invalid_blob_cid}

  defp storage(opts),
    do:
      Keyword.get(opts, :storage, Application.get_env(:atoll, :blob_storage, backend: :postgres))

  defp prepare_backend(did, cid, bytes, config) do
    case Repo.get_by(Blob, did: did, cid: cid) do
      %Blob{backend: backend} ->
        {:ok, backend}

      nil ->
        case Keyword.get(config, :backend, :postgres) do
          :postgres ->
            {:ok, :postgres}

          :s3 ->
            with :ok <- S3.put(cid, bytes, Keyword.get(config, :s3, [])), do: {:ok, :s3}

          _ ->
            {:error, :blob_storage_unavailable}
        end
    end
  end

  defp read_bytes(%Blob{backend: :postgres, cid: cid}, _), do: Storage.get_block(cid)

  defp read_bytes(%Blob{backend: :s3, cid: cid}, config),
    do: S3.get(cid, Keyword.get(config, :s3, []))

  defp descriptor(blob) do
    %{
      "$type" => "blob",
      "ref" => %{"$link" => CID.to_base32(blob.cid)},
      "mimeType" => blob.mime_type,
      "size" => blob.size
    }
  end

  defp size(bytes, expected) do
    cond do
      byte_size(bytes) > @max_size ->
        {:error, :blob_too_large}

      not is_nil(expected) and (not is_integer(expected) or expected != byte_size(bytes)) ->
        {:error, :content_length_mismatch}

      true ->
        :ok
    end
  end

  defp mime(value) when is_binary(value) and byte_size(value) <= 255 do
    # Accept a concrete media type only; parameters and wildcard ranges are not blob metadata.
    if Regex.match?(
         ~r/\A[a-zA-Z0-9][a-zA-Z0-9!#$&^_.+-]*\/[a-zA-Z0-9][a-zA-Z0-9!#$&^_.+-]*\z/,
         value
       ), do: {:ok, String.downcase(value)}, else: {:error, :invalid_mime_type}
  end

  defp mime(_), do: {:error, :invalid_mime_type}

  defp active_head!(did, lock) do
    query = from h in Head, where: h.did == ^did

    query =
      case lock do
        "FOR UPDATE" -> from h in query, lock: "FOR UPDATE"
        "FOR SHARE" -> from h in query, lock: "FOR SHARE"
      end

    head = Repo.one(query) || Repo.rollback(:not_found)

    case Repositories.availability(head) do
      :ok -> head
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
