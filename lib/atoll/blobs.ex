defmodule Atoll.Blobs do
  @moduledoc """
  Internal account-scoped blob staging, not an authorization boundary.

  Bytes are content-addressed in PostgreSQL or S3-compatible object storage. Ownership and
  MIME metadata belong to each repository. Public access requires a current
  record reference with matching metadata and an active repository.
  MIME declarations are normalized and common binary media signatures are detected.
  Detection does not decode or validate complete media files. The local size limit is
  5 MiB per blob. Expiration and queued cleanup have an opt-in scheduler;
  account quotas include staged and referenced ownership across both backends.
  Streaming and discovery of untracked orphan objects remain pending.
  """
  import Ecto.Query
  alias Atoll.{CID, Repo, Repositories, Storage}
  alias Atoll.Blobs.{Blob, Reference, S3, Takedown, Takedowns}
  alias Atoll.Repositories.{Events, Head}
  @max_size 5 * 1024 * 1024

  @doc "Maximum accepted blob upload size in bytes."
  def max_size, do: @max_size

  @doc "Stages an upload authorized by a live access token, with authorization held through commit."
  def stage_authenticated(token, bytes, content_type, opts \\ []) do
    with {:ok, claims} <- Atoll.Accounts.Tokens.verify(token, :access) do
      Repo.transaction(fn ->
        Events.lock!()
        # Acquire the write lock before the session lock to avoid a lock upgrade
        # deadlock with refresh, which takes a head share lock before its session lock.
        active_head!(claims["sub"], "FOR UPDATE", true)

        with {:ok, %{did: did}} <- Atoll.Accounts.Sessions.authenticate_session(token),
             {:ok, blob} <- stage_for_status(did, bytes, content_type, opts, true) do
          blob
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Stage bytes for an active hosted repository and return ATProto JSON blob metadata."
  def stage(did, bytes, content_type, opts \\ [])

  def stage(did, bytes, content_type, opts),
    do: stage_for_status(did, bytes, content_type, opts, false)

  defp stage_for_status(did, bytes, content_type, opts, allow_deactivated?)
       when is_binary(did) and is_binary(bytes) do
    with :ok <- size(bytes, Keyword.get(opts, :content_length)),
         {:ok, declared_mime} <- normalize_mime(content_type),
         mime = Atoll.Blobs.MimeSniffer.detect(bytes, declared_mime),
         {:ok, _} <- Repositories.get_head(did),
         cid = CID.create(bytes, :raw) do
      Repo.transaction(fn ->
        Events.lock!()
        active_head!(did, "FOR UPDATE", allow_deactivated?)
        Takedowns.ensure_available!(did, cid)
        check_quota!(did, cid, byte_size(bytes), opts)

        backend =
          case prepare_backend(did, cid, bytes, storage(opts)) do
            {:ok, backend} -> backend
            {:error, reason} -> Repo.rollback(reason)
          end

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
          ],
          on_conflict: {:replace, [:staged_at]},
          conflict_target: [:did, :cid]
        )

        # The first stored MIME type for this account/CID remains authoritative.
        descriptor(Repo.get_by!(Blob, did: did, cid: cid))
      end)
    end
  end

  defp stage_for_status(_, _, _, _, _), do: {:error, :invalid_blob}

  @doc "Internal staged-byte read. Never expose directly as getBlob or listBlobs."
  def get_staged(did, cid, opts \\ [])

  def get_staged(did, cid, opts) when is_binary(did) and is_binary(cid) do
    with {:ok, %{codec: :raw}} <- CID.decode(cid) do
      Repo.transaction(fn ->
        active_head!(did, "FOR SHARE")
        read_staged!(did, cid, opts)
      end)
    else
      _ -> {:error, :invalid_blob_cid}
    end
  end

  def get_staged(_, _, _), do: {:error, :invalid_blob_cid}

  defp read_staged!(did, cid, opts) do
    Takedowns.ensure_available!(did, cid)
    blob = Repo.get_by(Blob, did: did, cid: cid) || Repo.rollback(:blob_not_found)

    with {:ok, bytes} <- read_bytes(blob, storage(opts)),
         :ok <- CID.verify(cid, bytes),
         true <- byte_size(bytes) == blob.size do
      %{blob: descriptor(blob), bytes: bytes}
    else
      _ -> Repo.rollback(:invalid_blob_storage)
    end
  end

  @doc "Reads referenced blobs publicly for active repositories, or for a live owner export token."
  def get_public(did, cid, opts \\ []) do
    Repo.transaction(fn ->
      export_head!(did, opts[:token])

      unless Repo.exists?(from b in public_query(did), where: b.cid == ^cid),
        do: Repo.rollback(:blob_not_found)

      read_staged!(did, cid, opts)
    end)
  end

  @doc "Lists available referenced blobs with an exclusive CID cursor and optional reference revision."
  def list_public(did, limit, cursor \\ nil, since \\ nil, token \\ nil) when limit in 1..1000 do
    Repo.transaction(fn ->
      export_head!(did, token)
      query = public_query(did)
      query = if cursor, do: from(b in query, where: b.cid > ^cursor), else: query
      query = if since, do: from([b, r] in query, where: r.rev > ^since), else: query

      rows =
        Repo.all(
          from b in query, select: b.cid, distinct: true, order_by: b.cid, limit: ^(limit + 1)
        )

      page = Enum.take(rows, limit)
      result = %{cids: Enum.map(page, &CID.to_base32/1)}

      if length(rows) > limit,
        do: Map.put(result, :cursor, CID.to_base32(List.last(page))),
        else: result
    end)
  end

  defp export_head!(did, nil), do: active_head!(did, "FOR SHARE")

  defp export_head!(did, token) do
    case Atoll.Accounts.Sessions.authenticate_export(token, did) do
      {:ok, head} -> head
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp public_query(did) do
    from b in Blob,
      join: r in Reference,
      on: r.did == b.did and r.cid == b.cid and r.mime_type == b.mime_type and r.size == b.size,
      left_join: t in Takedown,
      on: t.did == b.did and t.cid == b.cid,
      where: b.did == ^did and is_nil(t.cid)
  end

  defp storage(opts),
    do:
      Keyword.get(opts, :storage, Application.get_env(:atoll, :blob_storage, backend: :postgres))

  defp check_quota!(did, cid, size, opts) do
    limits = Keyword.get(opts, :quota, Application.get_env(:atoll, :blob_quota, []))
    max_bytes = Keyword.get(limits, :max_bytes, 1_073_741_824)
    max_count = Keyword.get(limits, :max_count, 10_000)

    unless is_integer(max_bytes) and max_bytes >= 0 and
             is_integer(max_count) and max_count >= 0,
           do: Repo.rollback(:invalid_blob_quota)

    # Renewing existing ownership consumes no additional space, even after a limit decrease.
    unless Repo.exists?(from b in Blob, where: b.did == ^did and b.cid == ^cid) do
      {count, bytes} =
        Repo.one(
          from b in Blob,
            where: b.did == ^did,
            select: {count(b.cid), type(coalesce(sum(b.size), 0), :integer)}
        )

      if count + 1 > max_count or bytes + size > max_bytes,
        do: Repo.rollback(:blob_quota_exceeded)
    end
  end

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

  @doc false
  def normalize_mime(value) when is_binary(value) and byte_size(value) <= 255 do
    # Accept a concrete media type only; parameters and wildcard ranges are not blob metadata.
    if Regex.match?(
         ~r/\A[a-zA-Z0-9][a-zA-Z0-9!#$&^_.+-]*\/[a-zA-Z0-9][a-zA-Z0-9!#$&^_.+-]*\z/,
         value
       ), do: {:ok, String.downcase(value)}, else: {:error, :invalid_mime_type}
  end

  def normalize_mime(_), do: {:error, :invalid_mime_type}

  defp active_head!(did, lock, allow_deactivated? \\ false) do
    query = from h in Head, where: h.did == ^did

    query =
      case lock do
        "FOR UPDATE" -> from h in query, lock: "FOR UPDATE"
        "FOR SHARE" -> from h in query, lock: "FOR SHARE"
      end

    head = Repo.one(query) || Repo.rollback(:not_found)

    case Repositories.availability(head) do
      :ok -> head
      {:error, {:repo_inactive, :deactivated}} when allow_deactivated? -> head
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
