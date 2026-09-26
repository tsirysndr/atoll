defmodule Atoll.Repositories.Takedowns do
  @moduledoc "Internal record API visibility controls; callers must authorize administration."
  import Ecto.Query
  alias Atoll.{CID, Repo, Syntax}
  alias Atoll.Repositories.{Events, Head, Record, Takedown}
  @subject_type "com.atproto.repo.strongRef"

  def get(uri) do
    with {:ok, did, path} <- location(uri) do
      transaction(fn ->
        lock_head!(did, false)
        {record, marker} = subject!(did, path)
        view(did, path, record, marker)
      end)
    end
  end

  def update(
        %{"subject" => %{"$type" => @subject_type, "uri" => uri, "cid" => text} = subject} =
          params
      ) do
    with {:ok, did, path} <- location(uri),
         {:ok, cid} <- CID.from_base32(text),
         {:ok, %{codec: :dag_cbor}} <- CID.decode(cid),
         true <- Map.keys(subject) -- ["$type", "uri", "cid"] == [],
         true <- Map.keys(params) -- ["subject", "takedown"] == [],
         true <- Atoll.Accounts.SubjectStatus.attribute?(params, "takedown") do
      transaction(fn ->
        Events.lock!()
        lock_head!(did, true)
        {record, marker} = subject!(did, path)
        # Never apply an operator decision to a record that changed after review.
        unless cid == (record || marker).cid, do: Repo.rollback(:invalid_swap)

        marker =
          case Map.fetch(params, "takedown") do
            :error ->
              marker

            {:ok, %{"applied" => true} = attr} ->
              Repo.insert!(%Takedown{did: did, path: path, cid: cid, ref: attr["ref"]},
                on_conflict: {:replace, [:cid, :ref]},
                conflict_target: [:did, :path],
                log: false
              )

            {:ok, %{"applied" => false}} ->
              Repo.delete_all(from t in Takedown, where: t.did == ^did and t.path == ^path)
              nil
          end

        # A deleted record can still have its retained marker lifted.
        %{subject: subject, takedown: attribute(marker)}
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  def update(_), do: {:error, :invalid_request}

  @doc "Check under a head lock before a public record API read. Does not filter sync data."
  def ensure_visible!(did, path) do
    if Repo.exists?(from t in Takedown, where: t.did == ^did and t.path == ^path),
      do: Repo.rollback(:not_found)

    :ok
  end

  defp transaction(fun) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      Repo.query!("SET LOCAL statement_timeout = '5s'")
      fun.()
    end)
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] in [:lock_not_available, :query_canceled],
        do: {:error, :admin_busy},
        else: reraise(e, __STACKTRACE__)
  end

  defp lock_head!(did, write?) do
    query = from h in Head, where: h.did == ^did

    query =
      if write?,
        do: from(h in query, lock: "FOR UPDATE"),
        else: from(h in query, lock: "FOR SHARE")

    Repo.one(query) || Repo.rollback(:subject_not_found)
  end

  defp subject!(did, path) do
    record = Repo.get_by(Record, did: did, path: path)
    marker = Repo.get_by(Takedown, did: did, path: path)
    unless record || marker, do: Repo.rollback(:subject_not_found)
    {record, marker}
  end

  defp view(did, path, record, marker) do
    %{
      subject: %{
        "$type" => @subject_type,
        "uri" => "at://" <> did <> "/" <> path,
        "cid" => CID.to_base32((record || marker).cid)
      },
      takedown: attribute(marker)
    }
  end

  defp attribute(nil), do: %{applied: false}
  defp attribute(%Takedown{ref: nil}), do: %{applied: true}
  defp attribute(%Takedown{ref: ref}), do: %{applied: true, ref: ref}

  defp location("at://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [did, path] ->
        if Syntax.did?(did) and Syntax.repo_path?(path),
          do: {:ok, did, path},
          else: {:error, :invalid_request}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp location(_), do: {:error, :invalid_request}
end
