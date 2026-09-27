defmodule Atoll.MST.Proof do
  @moduledoc "Verifies a bounded MST search path against a caller-authenticated root, without requiring sibling subtrees."
  alias Atoll.Syntax
  alias Atoll.MST.Node
  alias Atoll.CBOR.Link

  def verify(root, key, blocks) when is_map(blocks) do
    case fetch(root, key, &Map.fetch(blocks, &1)) do
      {:ok, proof} -> {:ok, proof.cid}
      {:error, _} -> {:error, :invalid_mst_proof}
    end
  end

  def verify(_, _, _), do: {:error, :invalid_mst_proof}

  @doc """
  Loads and verifies only the requested search path from a CID reader.
  Returns its blocks and record CID (nil proves absence). The reader returns
  {:ok, bytes}; missing/corrupt nodes fail closed. A trusted :max_bytes option
  bounds retained node bytes (default 2 MiB, maximum 64 MiB), in addition to
  the per-node and depth bounds. Unvisited subtrees are not validated.
  """
  def fetch(root, key, reader, opts \\ []) when is_function(reader, 1) do
    limit = Keyword.get(opts, :max_bytes, 2 * 1024 * 1024)

    if Syntax.repo_path?(key) and is_integer(limit) and limit in 1..(64 * 1024 * 1024) do
      try do
        state = %{reader: reader, blocks: %{}, bytes: 0, limit: limit}
        {cid, state} = walk(root, key, state, nil, nil, nil, 0)
        {:ok, %{cid: cid, blocks: state.blocks}}
      catch
        :invalid_mst_proof -> {:error, :invalid_mst_proof}
        :mst_proof_too_large -> {:error, :mst_proof_too_large}
      end
    else
      {:error, :invalid_mst_proof}
    end
  end

  defp walk(cid, key, state, low, high, expected_level, depth) do
    if depth > 128, do: invalid!()
    {bytes, state} = read!(cid, state)

    case Node.decode(cid, bytes, low, high, expected_level, depth == 0) do
      {:ok, %{left: left, entries: entries, level: level}} ->
        search(entries, left, key, state, low, high, level, depth)

      _ ->
        invalid!()
    end
  end

  defp read!(cid, state) do
    unless Node.dag?(cid) and not Map.has_key?(state.blocks, cid), do: invalid!()

    case state.reader.(cid) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= 1_048_576 ->
        total = state.bytes + byte_size(bytes)
        if total > state.limit, do: throw(:mst_proof_too_large)
        {bytes, %{state | blocks: Map.put(state.blocks, cid, bytes), bytes: total}}

      _ ->
        invalid!()
    end
  end

  defp search([], child, key, state, low, high, level, depth),
    do: descend(child, key, state, low, high, level, depth)

  defp search([{current, value, right} | rest], left, key, state, low, high, level, depth) do
    cond do
      key == current -> {value, state}
      key < current -> descend(left, key, state, low, current, level, depth)
      true -> search(rest, right, key, state, current, high, level, depth)
    end
  end

  defp descend(nil, _, state, _, _, _, _), do: {nil, state}

  defp descend(%Link{cid: cid}, key, state, low, high, level, depth),
    do: walk(cid, key, state, low, high, level - 1, depth + 1)

  defp invalid!, do: throw(:invalid_mst_proof)
end
