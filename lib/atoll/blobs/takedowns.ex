defmodule Atoll.Blobs.Takedowns do
  @moduledoc "Internal operator blob restrictions. Callers must authorize administration."
  import Ecto.Query
  alias Atoll.{CID, Repo, Syntax}
  alias Atoll.Blobs.{Blob, Takedown}
  alias Atoll.Repositories.{Events, Head}
  @subject_type "com.atproto.admin.defs#repoBlobRef"

  def get(did, text) do
    with true <- Syntax.did?(did), {:ok, cid} <- raw_cid(text) do
      Repo.transaction(fn ->
        lock_head!(did, false)
        current = subject!(did, cid)
        view(did, cid, current)
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  def update(
        %{"subject" => %{"$type" => @subject_type, "did" => did, "cid" => text} = subject} =
          params
      ) do
    with true <- Syntax.did?(did),
         {:ok, cid} <- raw_cid(text),
         true <- Map.keys(subject) -- ["$type", "did", "cid", "recordUri"] == [],
         true <- record_uri?(subject, did),
         true <- Map.keys(params) -- ["subject", "takedown"] == [],
         true <- Atoll.Accounts.SubjectStatus.attribute?(params, "takedown") do
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '1s'")
        Repo.query!("SET LOCAL statement_timeout = '5s'")
        Events.lock!()
        lock_head!(did, true)
        current = subject!(did, cid)
        before_state = Map.delete(view(did, cid, current), :subject)

        current =
          case Map.fetch(params, "takedown") do
            :error ->
              current

            {:ok, %{"applied" => true} = attr} ->
              Repo.insert!(%Takedown{did: did, cid: cid, ref: attr["ref"]},
                on_conflict: {:replace, [:ref]},
                conflict_target: [:did, :cid],
                log: false
              )

            {:ok, %{"applied" => false}} ->
              Repo.delete_all(from t in Takedown, where: t.did == ^did and t.cid == ^cid)
              nil
          end

        result = view(did, cid, current)

        Atoll.Moderation.Audit.append!(
          did,
          result.subject,
          params,
          before_state,
          Map.delete(result, :subject)
        )

        result
      end)
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :admin_busy},
        else: reraise(e, __STACKTRACE__)
  end

  def update(_), do: {:error, :invalid_request}

  @doc "Check under the repository head lock before reading or accepting blob bytes."
  def ensure_available!(did, cid) do
    if Repo.exists?(from t in Takedown, where: t.did == ^did and t.cid == ^cid),
      do: Repo.rollback(:blob_taken_down)

    :ok
  end

  defp subject!(did, cid) do
    current = Repo.get_by(Takedown, did: did, cid: cid)

    unless current || Repo.exists?(from b in Blob, where: b.did == ^did and b.cid == ^cid),
      do: Repo.rollback(:subject_not_found)

    current
  end

  defp lock_head!(did, write?) do
    query = from h in Head, where: h.did == ^did

    query =
      if write?,
        do: from(h in query, lock: "FOR UPDATE"),
        else: from(h in query, lock: "FOR SHARE")

    Repo.one(query) || Repo.rollback(:subject_not_found)
  end

  defp view(did, cid, current) do
    attr = %{applied: not is_nil(current)}
    attr = if current && current.ref, do: Map.put(attr, :ref, current.ref), else: attr

    %{
      subject: %{"$type" => @subject_type, "did" => did, "cid" => CID.to_base32(cid)},
      takedown: attr
    }
  end

  defp raw_cid(text) do
    with {:ok, cid} <- CID.from_base32(text),
         {:ok, %{codec: :raw}} <- CID.decode(cid),
         do: {:ok, cid},
         else: (_ -> {:error, :invalid_request})
  end

  defp record_uri?(subject, did) do
    case Map.fetch(subject, "recordUri") do
      :error ->
        true

      {:ok, "at://" <> rest} ->
        case String.split(rest, "/", parts: 2) do
          [^did, path] -> Syntax.repo_path?(path)
          _ -> false
        end

      _ ->
        false
    end
  end
end
