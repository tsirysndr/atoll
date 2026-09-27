defmodule Atoll.Blobs.Inventory do
  @moduledoc "Read-only bounded inventory of current S3 objects under Atoll's blobs/ prefix."
  import Ecto.Query
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
        Repo.read_transaction(fn ->
          Atoll.Database.read_limits!()

          owned =
            from b in Atoll.Blobs.Blob,
              where: b.backend == :s3 and b.cid in ^cids,
              select: [b.cid, "owned"]

          pending =
            from j in Atoll.Blobs.CleanupJob,
              where: j.backend == :s3 and j.cid in ^cids,
              select: [j.cid, "pending_cleanup"]

          Repo.all(union(owned, ^pending), log: false)
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
    _ in [Exqlite.Error, Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, :inventory_unavailable}
  end

  defp cid("blobs/" <> text) do
    with {:ok, cid} <- CID.from_base32(text),
         {:ok, %{codec: :raw}} <- CID.decode(cid),
         do: {:ok, cid},
         else: (_ -> :invalid)
  end
end
