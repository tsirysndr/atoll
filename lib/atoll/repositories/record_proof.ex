defmodule Atoll.Repositories.RecordProof do
  @moduledoc "Verifies a record's signed CAR inclusion proof; trusted identity keys and freshness policy belong to the caller."
  alias Atoll.{CAR, CBOR, CID, Commit, DataModel}

  def verify(archive, did, path, curve, public)
      when is_binary(archive) and byte_size(archive) <= 2_097_152 do
    with {:ok, %{roots: [root | _], blocks: blocks}} <- CAR.decode(archive),
         {:ok, %{codec: :dag_cbor}} <- CID.decode(root),
         {:ok, commit} <- Commit.verify(Map.get(blocks, root), did, curve, public),
         {:ok, cid} when is_binary(cid) <-
           Atoll.MST.Proof.verify(commit["data"].cid, path, blocks),
         bytes when is_binary(bytes) and byte_size(bytes) <= 1_000_000 <- Map.get(blocks, cid),
         {:ok, value} when is_map(value) <- CBOR.decode(bytes),
         {:ok, record} <- DataModel.to_json(value),
         [collection, _] <- String.split(path, "/"),
         true <- record["$type"] == collection do
      {:ok, %{cid: cid, record: record, commit: root, rev: commit["rev"]}}
    else
      _ -> {:error, :invalid_record_proof}
    end
  end

  def verify(_, _, _, _, _), do: {:error, :invalid_record_proof}
end
