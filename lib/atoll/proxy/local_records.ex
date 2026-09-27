defmodule Atoll.Proxy.LocalRecords do
  @moduledoc """
  Recent local record writes newer than an AppView's indexed revision.

  Reads the durable commit outbox instead of live repository state, bounded to
  the newest thirty commits and ten records, mirroring the reference reader's
  ten-row page. A revision at or before the AppView's reported revision must
  exist locally, so a rebuilt or migrated repository is never munged from an
  unrelated clock. Failures degrade to an empty result.
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
        |> Enum.flat_map(&decode(&1, rev))
        |> Enum.reverse()
        |> Enum.take(@record_limit)

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
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> %{posts: [], profile: nil}
  end

  defp decode(event, since) do
    with {:ok, %{"rev" => rev, "ops" => ops}} when rev > since <- CBOR.decode(event.payload) do
      ops
      |> Enum.filter(&(&1["action"] in ["create", "update"]))
      |> Enum.flat_map(&descript(event, rev, &1))
      |> Enum.reverse()
    else
      _ -> []
    end
  end

  defp descript(event, _rev, %{"path" => path, "cid" => %CBOR.Link{cid: cid}})
       when is_binary(path) do
    with {:ok, bytes} <- Storage.get_block(cid),
         {:ok, decoded} <- CBOR.decode(bytes),
         {:ok, record} <- DataModel.to_json(decoded) do
      [
        %{
          uri: "at://" <> event.did <> "/" <> path,
          path: path,
          cid: CID.to_base32(cid),
          indexed_at: event.time |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
          record: record
        }
      ]
    else
      _ -> []
    end
  end

  defp descript(_, _, _), do: []
end
