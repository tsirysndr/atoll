defmodule Atoll.MST do
  @moduledoc """
  Deterministic ATProto Merkle Search Trees.

  This initial implementation rebuilds the tree on mutation. It prioritizes
  canonical serialization over incremental-update performance.
  """
  alias Atoll.{CBOR, CID, Syntax}
  alias Atoll.CBOR.{Bytes, Link}
  defstruct records: %{}, root: nil, blocks: %{}

  def new(records \\ %{}) when is_map(records) do
    if Enum.all?(records, fn {key, cid} ->
         Syntax.repo_path?(key) and is_binary(cid) and
           match?({:ok, %{codec: :dag_cbor}}, CID.decode(cid))
       end) do
      items = records |> Enum.map(fn {key, cid} -> {key, cid, height(key)} end) |> Enum.sort()

      {root, blocks} =
        case items do
          [] -> store(%{"l" => nil, "e" => []}, %{})
          _ -> build(items, Enum.max(Enum.map(items, &elem(&1, 2))), %{})
        end

      {:ok, %__MODULE__{records: records, root: root, blocks: blocks}}
    else
      {:error, :invalid_mst}
    end
  end

  def get(%__MODULE__{records: records}, key), do: Map.fetch(records, key)
  def put(%__MODULE__{records: records}, key, cid), do: new(Map.put(records, key, cid))
  def delete(%__MODULE__{records: records}, key), do: new(Map.delete(records, key))

  @doc "Loads verified blocks and requires the reconstructed canonical root to match."
  def load(root, blocks) when is_binary(root) and is_map(blocks) do
    try do
      {records, _seen} = read_node(root, blocks, %{}, MapSet.new(), 0)

      case new(records) do
        {:ok, %__MODULE__{root: ^root} = tree} -> {:ok, tree}
        _ -> {:error, :invalid_mst}
      end
    catch
      :invalid_mst -> {:error, :invalid_mst}
    end
  end

  def height(key) when is_binary(key), do: zeros(:crypto.hash(:sha256, key), 0)
  defp zeros(<<0::2, rest::bitstring>>, count), do: zeros(rest, count + 1)
  defp zeros(_, count), do: count

  defp build([], _, blocks), do: {nil, blocks}

  defp build(items, level, blocks) do
    {left, rest} = Enum.split_while(items, &(elem(&1, 2) < level))
    {left_cid, blocks} = build(left, level - 1, blocks)
    {entries, blocks} = build_entries(rest, level, "", [], blocks)
    store(%{"l" => link(left_cid), "e" => Enum.reverse(entries)}, blocks)
  end

  defp build_entries([], _, _, result, blocks), do: {result, blocks}

  defp build_entries([{key, cid, level} | tail], level, previous, result, blocks) do
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

    build_entries(rest, level, key, [entry | result], blocks)
  end

  defp common_prefix(<<c, a::binary>>, <<c, b::binary>>, n), do: common_prefix(a, b, n + 1)
  defp common_prefix(_, _, n), do: n
  defp link(nil), do: nil
  defp link(cid), do: %Link{cid: cid}

  defp store(node, blocks) do
    bytes = CBOR.encode!(node)
    cid = CID.create(bytes, :dag_cbor)
    {cid, Map.put(blocks, cid, bytes)}
  end

  defp read_node(cid, blocks, records, seen, depth) do
    if depth > 128 or MapSet.size(seen) >= 100_000 or MapSet.member?(seen, cid), do: invalid!()
    bytes = Map.get(blocks, cid)
    unless is_binary(bytes) and CID.verify(cid, bytes) == :ok, do: invalid!()

    case CBOR.decode(bytes) do
      {:ok, %{"l" => left, "e" => entries} = node}
      when map_size(node) == 2 and is_list(entries) ->
        seen = MapSet.put(seen, cid)
        {records, seen} = read_child(left, blocks, records, seen, depth)

        {records, seen, _key} =
          Enum.reduce(entries, {records, seen, ""}, fn entry, {acc, visited, previous} ->
            case entry do
              %{"p" => p, "k" => %Bytes{data: suffix}, "v" => %Link{cid: value}, "t" => right}
              when map_size(entry) == 4 and is_integer(p) and p >= 0 and p <= byte_size(previous) ->
                key = binary_part(previous, 0, p) <> suffix
                if Map.has_key?(acc, key) or map_size(acc) >= 1_000_000, do: invalid!()

                {acc, visited} =
                  read_child(right, blocks, Map.put(acc, key, value), visited, depth)

                {acc, visited, key}

              _ ->
                invalid!()
            end
          end)

        {records, seen}

      _ ->
        invalid!()
    end
  end

  defp read_child(nil, _, records, seen, _), do: {records, seen}

  defp read_child(%Link{cid: cid}, blocks, records, seen, depth),
    do: read_node(cid, blocks, records, seen, depth + 1)

  defp read_child(_, _, _, _, _), do: invalid!()
  defp invalid!, do: throw(:invalid_mst)
end
