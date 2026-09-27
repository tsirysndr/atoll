defmodule Atoll.MST.Traversal do
  @moduledoc """
  Lazy canonical MST traversal with bounded pending metadata.

  Emits {:node, cid, bytes} once per node and {:record, path, cid} in bytewise
  key order. Only a bounded stack of pending branches/entries is retained; there
  is no whole-tree record map or visited-node set. Inherited disjoint key ranges,
  exact levels and nonempty subtrees preclude repeated valid nodes. Full
  validation requires exhausting the stream. Cancellation reads no further blocks.
  Invalid/missing nodes or policy limits raise TraversalError during enumeration.
  The pending-byte budget charges encoded bytes, expanded keys and a fixed
  per-entry allowance; it is a metadata accounting bound, not an exact heap size.
  """
  alias Atoll.MST.{Node, TraversalError}
  alias Atoll.CBOR.Link

  def stream(root, reader, opts \\ []) when is_function(reader, 1) do
    limits = %{
      bytes: Keyword.get(opts, :max_pending_bytes, 16 * 1024 * 1024),
      nodes: Keyword.get(opts, :max_nodes, 100_000),
      records: Keyword.get(opts, :max_records, 1_000_000)
    }

    unless Enum.all?(limits, fn {_, n} -> is_integer(n) and n > 0 end),
      do: raise(ArgumentError, "MST traversal limits must be positive integers")

    Stream.resource(
      fn -> %{stack: [{:visit, root, nil, nil, nil, 0}], bytes: 0, nodes: 0, records: 0} end,
      &next(&1, reader, limits),
      fn _ -> :ok end
    )
  end

  defp next(%{stack: []} = state, _, _), do: {:halt, state}

  defp next(%{stack: [{:release, bytes} | rest]} = state, reader, limits),
    do: next(%{state | stack: rest, bytes: state.bytes - bytes}, reader, limits)

  defp next(%{stack: [{:entries, [], _, _, _} | rest]} = state, reader, limits),
    do: next(%{state | stack: rest}, reader, limits)

  defp next(
         %{stack: [{:entries, [{key, cid, right} | entries], high, level, depth} | rest]} = state,
         _reader,
         limits
       ) do
    if state.records >= limits.records, do: invalid!()

    upper =
      case entries do
        [{next, _, _} | _] -> next
        [] -> high
      end

    stack = [{:entries, entries, high, level, depth} | rest]
    stack = child(right, key, upper, level, depth, stack)
    {[{:record, key, cid}], %{state | stack: stack, records: state.records + 1}}
  end

  defp next(%{stack: [{:visit, cid, low, high, expected, depth} | rest]} = state, reader, limits) do
    if depth > 128 or state.nodes >= limits.nodes or not Node.dag?(cid), do: invalid!()

    with {:ok, bytes} when is_binary(bytes) <- reader.(cid),
         true <- state.bytes + byte_size(bytes) <= limits.bytes,
         {:ok, node} <- Node.decode(cid, bytes, low, high, expected, depth == 0) do
      charge =
        byte_size(bytes) +
          Enum.reduce(node.entries, 0, fn {key, _, _}, n -> n + byte_size(key) + 128 end)

      if state.bytes + charge > limits.bytes, do: invalid!()

      upper =
        case node.entries do
          [{first, _, _} | _] -> first
          [] -> high
        end

      stack = [{:entries, node.entries, high, node.level, depth}, {:release, charge} | rest]
      stack = child(node.left, low, upper, node.level, depth, stack)

      {[{:node, cid, bytes}],
       %{state | stack: stack, bytes: state.bytes + charge, nodes: state.nodes + 1}}
    else
      _ -> invalid!()
    end
  end

  defp child(nil, _, _, _, _, stack), do: stack

  defp child(%Link{cid: cid}, low, high, level, depth, stack),
    do: [{:visit, cid, low, high, level - 1, depth + 1} | stack]

  defp invalid!, do: raise(TraversalError)
end
