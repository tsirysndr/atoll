defmodule Atoll.Proxy.LocalRecords do
  @moduledoc """
  Recent local record writes newer than an AppView's indexed revision.

  Folds the durable commit outbox chronologically, so an updated path appears
  once at its newest content and a deleted path disappears, matching the
  reference reader over current rows. Bounded to the newest thirty commits and
  ten records, mirroring the reference ten-row page. A revision at or before
  the AppView's reported revision must exist locally, so a rebuilt or migrated
  repository is never munged from an unrelated clock. Failures degrade to an
  empty result.
  """
  import Ecto.Query
  alias Atoll.{CBOR, CID, DataModel, Repo, Storage, TID}
  alias Atoll.Repositories.{Event, Revision}

  @scan_limit 30
  @record_limit 10

  @doc "Posts and the profile write since the revision, oldest first, as JSON descripts."
  def since(did, rev) do
    if is_binary(rev) and TID.valid?(rev) and
         Repo.exists?(from r in Revision, where: r.did == ^did and r.rev <= ^rev) do
      records =
        Repo.all(
          from e in Event,
            where: e.did == ^did and e.kind == :commit,
            order_by: [desc: e.seq],
            limit: @scan_limit
        )
        |> Enum.reverse()
        |> Enum.flat_map(&decode_ops(&1, rev))
        |> Enum.reduce(%{}, fn op, acc ->
          if op.action == "delete", do: Map.delete(acc, op.path), else: Map.put(acc, op.path, op)
        end)
        |> Map.values()
        |> Enum.sort_by(& &1.rev)
        |> Enum.take(@record_limit)
        |> Enum.flat_map(&descript(did, &1))

      %{
        posts: Enum.filter(records, &String.starts_with?(&1.path, "app.bsky.feed.post/")),
        profile:
          records
          |> Enum.filter(&(&1.path == "app.bsky.actor.profile/self"))
          |> List.last()
      }
    else
      %{posts: [], profile: nil}
    end
  rescue
    _ in [Exqlite.Error, Postgrex.Error, DBConnection.ConnectionError] ->
      %{posts: [], profile: nil}
  end

  defp decode_ops(event, since) do
    with {:ok, %{"rev" => rev, "ops" => ops}} when rev > since and is_list(ops) <-
           CBOR.decode(event.payload) do
      for %{"action" => action, "path" => path} = op <- ops,
          is_binary(action) and is_binary(path) do
        %{action: action, path: path, cid: op["cid"], rev: rev, time: event.time}
      end
    else
      _ -> []
    end
  end

  defp descript(did, %{path: path, cid: %CBOR.Link{cid: cid}} = op) do
    with {:ok, bytes} <- Storage.get_block(cid),
         {:ok, decoded} <- CBOR.decode(bytes),
         {:ok, record} <- DataModel.to_json(decoded) do
      [
        %{
          uri: "at://" <> did <> "/" <> path,
          path: path,
          cid: CID.to_base32(cid),
          indexed_at: op.time |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
          record: record
        }
      ]
    else
      _ -> []
    end
  end

  defp descript(_, _), do: []
end
