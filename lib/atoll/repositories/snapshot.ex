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
    with {:ok, %{roots: roots, blocks: blocks}} <- CAR.decode(archive),
         {:ok, snapshot} <- validate(roots, &Map.fetch(blocks, &1), did, curve, public) do
      {:ok,
       snapshot
       |> Map.delete(:block_cids)
       |> Map.put(:blocks, Map.take(blocks, snapshot.block_cids))}
    else
      {:error, :car_too_large} = error -> error
      _ -> {:error, :invalid_snapshot}
    end
  end

  @doc """
  Validate staged blocks without retaining record bodies. The returned reader is
  valid only inside the Stage.with_chunks callback. No repository data is published.
  Metadata and the reconstructed MST still scale with repository size.
  """
  def from_stage(%Atoll.CAR.Stage{} = stage, did, curve, public) do
    reader = &Atoll.CAR.Stage.read(stage, &1)

    with {:ok, snapshot} <- validate(stage.roots, reader, did, curve, public),
         do: {:ok, Map.put(snapshot, :read_block, reader)}
  end

  defp validate([root], reader, did, curve, public) do
    with {:ok, %{codec: :dag_cbor}} <- CID.decode(root),
         {:ok, bytes} <- reader.(root),
         {:ok, commit} <- Commit.verify(bytes, did, curve, public),
         {:ok, revision} <- TID.decode(commit["rev"]),
         true <- div(revision, 1024) <= System.system_time(:microsecond) + 300_000_000,
         {:ok, tree} <- MST.load(commit["data"].cid, reader),
         :ok <- validate_records(tree.records, reader) do
      {:ok,
       %{
         head: root,
         data: tree.root,
         rev: commit["rev"],
         records: tree.records,
         block_cids: Enum.uniq([root | Map.keys(tree.blocks) ++ Map.values(tree.records)])
       }}
    else
      _ -> {:error, :invalid_snapshot}
    end
  end

  defp validate(_, _, _, _, _), do: {:error, :invalid_snapshot}

  defp validate_records(records, reader) do
    Enum.reduce_while(records, :ok, fn {path, cid}, :ok ->
      [collection, _] = String.split(path, "/")

      with {:ok, bytes} <- reader.(cid),
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
