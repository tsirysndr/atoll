defmodule Atoll.MST do
  @moduledoc """
  Deterministic ATProto Merkle Search Trees.

  The buffered constructor rebuilds the tree on mutation and remains a canonical
  reference implementation. Loading uses bounded canonical traversal and caps
  retained metadata. Production streaming construction and partial edits live in
  MST.Builder and MST.Editor respectively.
  """
  alias Atoll.{CBOR, CID, Syntax}
  alias Atoll.CBOR.{Bytes, Link}
  defstruct records: %{}, root: nil, blocks: %{}

  @doc "Builds a buffered canonical tree within :max_bytes (default 64 MiB) of retained metadata accounting."
  def new(records \\ %{}, opts \\ [])

  def new(records, opts) when is_map(records) do
    max_bytes = buffer_limit!(opts)

    try do
      if map_size(records) > 1_000_000, do: throw(:mst_too_large)

      used =
        Enum.reduce(records, 0, fn {key, cid}, used ->
          unless Syntax.repo_path?(key) and is_binary(cid) and
                   match?({:ok, %{codec: :dag_cbor}}, CID.decode(cid)),
                 do: throw(:invalid_mst)

          size = used + byte_size(key) + byte_size(cid) + 128
          if size > max_bytes, do: throw(:mst_too_large)
          size
        end)

      state = %{blocks: %{}, used: used, limit: max_bytes}
      items = records |> Enum.map(fn {key, cid} -> {key, cid, height(key)} end) |> Enum.sort()

      {root, state} =
        case items do
          [] -> store(%{"l" => nil, "e" => []}, state)
          _ -> build(items, Enum.reduce(items, 0, &max(elem(&1, 2), &2)), state)
        end

      {:ok, %__MODULE__{records: records, root: root, blocks: state.blocks}}
    catch
      reason when reason in [:invalid_mst, :mst_too_large] -> {:error, reason}
    end
  end

  def new(_, _), do: {:error, :invalid_mst}

  def get(%__MODULE__{records: records}, key), do: Map.fetch(records, key)

  def put(%__MODULE__{records: records}, key, cid, opts \\ []),
    do: new(Map.put(records, key, cid), opts)

  def delete(%__MODULE__{records: records}, key, opts \\ []),
    do: new(Map.delete(records, key), opts)

  @doc "Returns the search-path blocks and optional record CID from a constructed or fully validated tree."
  def proof(%__MODULE__{} = tree, key) do
    if Syntax.repo_path?(key) do
      {:ok, search(tree.root, key, tree.blocks, %{})}
    else
      {:error, :invalid_mst}
    end
  end

  defp search(nil, _, _, proof), do: %{cid: nil, blocks: proof}

  defp search(cid, key, blocks, proof) do
    bytes = Map.fetch!(blocks, cid)
    {:ok, %{"l" => left, "e" => entries}} = CBOR.decode(bytes)
    proof = Map.put(proof, cid, bytes)

    case search_entries(entries, key, "", left) do
      {:found, value} -> %{cid: value, blocks: proof}
      {:child, nil} -> search(nil, key, blocks, proof)
      {:child, %Link{cid: child}} -> search(child, key, blocks, proof)
    end
  end

  defp search_entries([], _, _, child), do: {:child, child}

  defp search_entries([entry | rest], key, previous, left) do
    current = binary_part(previous, 0, entry["p"]) <> entry["k"].data

    cond do
      key == current -> {:found, entry["v"].cid}
      key < current -> {:child, left}
      true -> search_entries(rest, key, current, entry["t"])
    end
  end

  @doc """
  Materializes a canonically validated tree from a block map or CID reader.

  The retained metadata budget defaults to 64 MiB and can be set with :max_bytes.
  Accounting includes encoded nodes, expanded record paths, CIDs and fixed map
  entry allowances; it is not an exact BEAM heap measurement. Traversal retains
  its independent pending-node/depth/count limits. Use MST.Traversal.stream/3
  when the caller does not need the entire tree in memory.
  """
  def load(root, blocks, opts \\ [])

  def load(root, blocks, opts)
      when is_binary(root) and (is_map(blocks) or is_function(blocks, 1)) do
    max_bytes = buffer_limit!(opts)

    reader = if is_map(blocks), do: &Map.fetch(blocks, &1), else: blocks

    root
    |> Atoll.MST.Traversal.stream(reader)
    |> Enum.reduce_while({:ok, %__MODULE__{root: root}, 0}, fn event, {:ok, tree, used} ->
      {field, key, value, charge} =
        case event do
          {:node, cid, bytes} ->
            {:blocks, cid, bytes, byte_size(bytes) + byte_size(cid) + 96}

          {:record, path, cid} ->
            {:records, path, cid, byte_size(path) + byte_size(cid) + 128}
        end

      if used + charge > max_bytes do
        {:halt, {:error, :mst_too_large}}
      else
        tree = Map.update!(tree, field, &Map.put(&1, key, value))
        {:cont, {:ok, tree, used + charge}}
      end
    end)
    |> case do
      {:ok, tree, _used} -> {:ok, tree}
      error -> error
    end
  rescue
    Atoll.MST.TraversalError -> {:error, :invalid_mst}
  end

  def load(_, _, _), do: {:error, :invalid_mst}

  defp buffer_limit!(opts) do
    limit = Keyword.get(opts, :max_bytes, 64 * 1024 * 1024)

    unless is_integer(limit) and limit > 0,
      do: raise(ArgumentError, "MST buffered metadata limit must be a positive integer")

    limit
  end

  def height(key) when is_binary(key), do: zeros(:crypto.hash(:sha256, key), 0)
  defp zeros(<<0::2, rest::bitstring>>, count), do: zeros(rest, count + 1)
  defp zeros(_, count), do: count

  defp build([], _, blocks), do: {nil, blocks}

  defp build(items, level, blocks) do
    {left, rest} = Enum.split_while(items, &(elem(&1, 2) < level))
    {left_cid, blocks} = build(left, level - 1, blocks)
    {entries, blocks} = build_entries(rest, level, "", [], blocks, 0)
    store(%{"l" => link(left_cid), "e" => Enum.reverse(entries)}, blocks)
  end

  defp build_entries([], _, _, result, blocks, _count), do: {result, blocks}

  defp build_entries([{key, cid, level} | tail], level, previous, result, blocks, count) do
    if count >= 10_000, do: throw(:mst_too_large)
    {right, rest} = Enum.split_while(tail, &(elem(&1, 2) < level))
    {right_cid, blocks} = build(right, level - 1, blocks)
    prefix = common_prefix(previous, key, 0)
    suffix = binary_part(key, prefix, byte_size(key) - prefix)

    entry = %{
      "p" => prefix,
      "k" => %Bytes{data: suffix},
      "v" => link(cid),
      "t" => link(right_cid)
    }

    build_entries(rest, level, key, [entry | result], blocks, count + 1)
  end

  defp common_prefix(<<c, a::binary>>, <<c, b::binary>>, n), do: common_prefix(a, b, n + 1)
  defp common_prefix(_, _, n), do: n
  defp link(nil), do: nil
  defp link(cid), do: %Link{cid: cid}

  defp store(node, state) do
    bytes = CBOR.encode!(node)
    if byte_size(bytes) > 1_048_576, do: throw(:mst_too_large)
    cid = CID.create(bytes, :dag_cbor)

    if Map.has_key?(state.blocks, cid) do
      {cid, state}
    else
      used = state.used + byte_size(bytes) + byte_size(cid) + 96

      if used > state.limit or map_size(state.blocks) >= 100_000,
        do: throw(:mst_too_large)

      {cid, %{state | blocks: Map.put(state.blocks, cid, bytes), used: used}}
    end
  end
end
