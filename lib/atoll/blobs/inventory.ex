defmodule Atoll.Blobs.Inventory do
  @moduledoc "Read-only bounded inventory of current S3 objects under Atoll's blobs/ prefix."
  alias Atoll.{CID, Repo}
  alias Atoll.Blobs.S3

  def page(limit \\ 100, cursor \\ nil, opts \\ []) do
    storage = Keyword.get(opts, :storage, Application.get_env(:atoll, :blob_storage, []))

    with :s3 <- storage[:backend],
         {:ok, page} <- S3.list(storage[:s3] || [], limit, cursor),
         true <- is_nil(page.cursor) or page.cursor != cursor do
      decoded = Enum.map(page.objects, &{&1, cid(&1.key)})
      cids = for {_, {:ok, cid}} <- decoded, do: cid

      {:ok, states} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL statement_timeout = '5s'")
          Repo.query!("SET LOCAL lock_timeout = '1s'")

          Repo.query!(
            """
            SELECT cid, 'owned' FROM repository_blobs WHERE backend = 's3' AND cid = ANY($1::bytea[])
            UNION
            SELECT cid, 'pending_cleanup' FROM blob_cleanup_jobs WHERE backend = 's3' AND cid = ANY($1::bytea[])
            """,
            [cids],
            log: false
          ).rows
        end)

      owned = for [cid, "owned"] <- states, into: MapSet.new(), do: cid
      pending = for [cid, "pending_cleanup"] <- states, into: MapSet.new(), do: cid

      objects =
        Enum.map(decoded, fn
          {object, {:ok, cid}} ->
            status =
              cond do
                MapSet.member?(owned, cid) -> "owned"
                MapSet.member?(pending, cid) -> "pending_cleanup"
                true -> "untracked"
              end

            Map.merge(object, %{cid: CID.to_base32(cid), status: status})

          {object, _} ->
            Map.put(object, :status, "unrecognized_key")
        end)

      result = %{objects: objects, counts: Enum.frequencies_by(objects, & &1.status)}
      {:ok, if(page.cursor, do: Map.put(result, :cursor, page.cursor), else: result)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_inventory_query}
    end
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :inventory_unavailable}
  end

  defp cid("blobs/" <> text) do
    with {:ok, cid} <- CID.from_base32(text),
         {:ok, %{codec: :raw}} <- CID.decode(cid),
         do: {:ok, cid},
         else: (_ -> :invalid)
  end
end
