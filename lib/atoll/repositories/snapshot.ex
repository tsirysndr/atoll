defmodule Atoll.Repositories.Snapshot do
  @moduledoc """
  Validates a complete CAR snapshot against a caller-supplied DID and trusted key.

  Requires all MST and record blocks, but permits dangling links inside records
  (for example blobs and external records). Unreferenced blocks are discarded.
  Record type and data-model checks are not Lexicon validation. The local import
  policy limits records to 1 MB and revisions to five minutes ahead of the clock.
  """
  alias Atoll.{CAR, CBOR, CID, Commit, DataModel, MST, TID}

  def decode(archive, did, curve, public) do
    with {:ok, %{roots: [root | _], blocks: blocks}} <- CAR.decode(archive),
         {:ok, %{codec: :dag_cbor}} <- CID.decode(root),
         {:ok, bytes} <- Map.fetch(blocks, root),
         {:ok, commit} <- Commit.verify(bytes, did, curve, public),
         {:ok, revision} <- TID.decode(commit["rev"]),
         true <- div(revision, 1024) <= System.system_time(:microsecond) + 300_000_000,
         {:ok, tree} <- MST.load(commit["data"].cid, blocks),
         :ok <- validate_records(tree.records, blocks) do
      reachable = [root | Map.keys(tree.blocks) ++ Map.values(tree.records)]

      {:ok,
       %{
         head: root,
         rev: commit["rev"],
         records: tree.records,
         blocks: Map.take(blocks, reachable)
       }}
    else
      {:error, :car_too_large} = error -> error
      _ -> {:error, :invalid_snapshot}
    end
  end

  defp validate_records(records, blocks) do
    Enum.reduce_while(records, :ok, fn {path, cid}, :ok ->
      [collection, _] = String.split(path, "/")

      with {:ok, bytes} <- Map.fetch(blocks, cid),
           true <- byte_size(bytes) <= 1_000_000,
           {:ok, %{"$type" => ^collection} = record} <- CBOR.decode(bytes),
           {:ok, _} <- DataModel.to_json(record) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :invalid_snapshot}}
      end
    end)
  end
end
