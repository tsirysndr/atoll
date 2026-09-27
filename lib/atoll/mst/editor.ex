defmodule Atoll.MST.Editor do
  @moduledoc """
  Canonical edits over a partial MST, fetching only search and split/merge boundaries.
  Returns the new root, fetched proof nodes and generated nodes; performs no writes.
  Unvisited subtrees remain opaque CID links. The caller authenticates the root.
  """
  alias Atoll.{CBOR, CID, MST, Syntax}
  alias Atoll.CBOR.{Bytes, Link}

  def apply(root, operations, reader, opts \\ []) when is_function(reader, 1) do
    limit = Keyword.get(opts, :max_bytes, 16 * 1024 * 1024)

    unless is_integer(limit) and limit > 0,
      do: raise(ArgumentError, "invalid MST editor byte limit")

    if is_list(operations) and length(operations) <= 200 do
      state = %{reader: reader, fetched: %{}, created: %{}, bytes: 0, limit: limit}

      try do
        {root, state} = Enum.reduce(operations, {root, state}, &edit/2)
        {_node, state} = read(root, nil, nil, nil, true, state)
        {:ok, %{root: root, fetched: state.fetched, created: state.created}}
      catch
        {:mst_editor, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_mst_edit}
    end
  end

  defp edit(operation, {root, state}) do
    {path, value} =
      case operation do
        {:put, path, value} ->
          unless MST.Node.dag?(value), do: fail!(:invalid_mst_edit)
          {path, value}

        {:delete, path} ->
          {path, nil}

        _ ->
          fail!(:invalid_mst_edit)
      end

    unless Syntax.repo_path?(path), do: fail!(:invalid_mst_edit)
    {node, state} = read(root, nil, nil, nil, true, state)
    level = node.level

    cond do
      is_nil(level) and is_nil(value) ->
        {root, state}

      is_nil(value) ->
        {cid, state} = delete(root, level, nil, nil, path, state)
        normalize(cid, level, state)

      true ->
        height = MST.height(path)

        {cid, state} =
          put(
            if(is_nil(level), do: nil, else: root),
            level || height,
            nil,
            nil,
            path,
            value,
            height,
            state
          )

        normalize(cid, max(level || height, height), state)
    end
  end

  defp put(nil, level, _low, _high, path, value, height, state) do
    {cid, state} = store(nil, [{path, value, nil}], state)
    lift(cid, height, level, state)
  end

  defp put(cid, level, low, high, path, value, height, state) when height > level do
    {left, right, state} = split(cid, level, low, high, path, state)
    {left, state} = lift(left, level, height - 1, state)
    {right, state} = lift(right, level, height - 1, state)
    store(left, [{path, value, right}], state)
  end

  defp put(cid, level, low, high, path, value, height, state) do
    {node, state} = read(cid, low, high, level, false, state)
    {before, after_entries, child, lower, upper} = boundary(node, path, low, high)

    case after_entries do
      [{^path, _, right} | rest] ->
        store(node.left, before ++ [{path, value, right} | rest], state)

      _ when height == level ->
        {left, right, state} = split(child, level - 1, lower, upper, path, state)

        {first, entries} =
          replace_boundary(node.left, before, left, [{path, value, right} | after_entries])

        store(first, entries, state)

      _ ->
        {child, state} = put(child, level - 1, lower, upper, path, value, height, state)
        {first, entries} = replace_boundary(node.left, before, child, after_entries)
        store(first, entries, state)
    end
  end

  defp delete(nil, _, _, _, _, state), do: {nil, state}

  defp delete(cid, level, low, high, path, state) do
    {node, state} = read(cid, low, high, level, false, state)
    {before, after_entries, child, lower, upper} = boundary(node, path, low, high)

    {child, tail, state} =
      case after_entries do
        [{^path, _, right} | rest] ->
          high_right =
            case rest do
              [{key, _, _} | _] -> key
              [] -> high
            end

          {merged, state} = merge(child, right, level - 1, lower, path, high_right, state)
          {merged, rest, state}

        _ ->
          {child, state} = delete(child, level - 1, lower, upper, path, state)
          {child, after_entries, state}
      end

    {first, entries} = replace_boundary(node.left, before, child, tail)
    store(first, entries, state)
  end

  defp split(nil, _, _, _, _, state), do: {nil, nil, state}

  defp split(cid, level, low, high, path, state) do
    {node, state} = read(cid, low, high, level, false, state)
    {before, after_entries, child, lower, upper} = boundary(node, path, low, high)
    if match?([{^path, _, _} | _], after_entries), do: fail!(:invalid_mst_edit)
    {left_child, right_child, state} = split(child, level - 1, lower, upper, path, state)
    {first, entries} = replace_boundary(node.left, before, left_child, [])
    {left, state} = store(first, entries, state)
    {right, state} = store(right_child, after_entries, state)
    {left, right, state}
  end

  defp merge(nil, right, _, _, _, _, state), do: {right, state}
  defp merge(left, nil, _, _, _, _, state), do: {left, state}

  defp merge(left, right, level, low, middle, high, state) do
    {a, state} = read(left, low, middle, level, false, state)
    {b, state} = read(right, middle, high, level, false, state)

    {edge, lower} =
      case List.last(a.entries) do
        nil -> {a.left, low}
        {key, _, child} -> {child, key}
      end

    upper =
      case b.entries do
        [{key, _, _} | _] -> key
        [] -> high
      end

    {child, state} = merge(edge, b.left, level - 1, lower, middle, upper, state)
    {first, entries} = replace_boundary(a.left, a.entries, child, b.entries)
    store(first, entries, state)
  end

  defp boundary(node, path, low, high) do
    {before, after_entries} = Enum.split_while(node.entries, fn {key, _, _} -> key < path end)

    {child, lower} =
      case List.last(before) do
        nil -> {node.left, low}
        {key, _, child} -> {child, key}
      end

    upper =
      case after_entries do
        [{key, _, _} | _] -> key
        [] -> high
      end

    {before, after_entries, child, lower, upper}
  end

  defp replace_boundary(_left, [], child, after_entries), do: {child, after_entries}

  defp replace_boundary(left, before, child, after_entries) do
    {key, value, _} = List.last(before)
    {left, Enum.drop(before, -1) ++ [{key, value, child} | after_entries]}
  end

  defp lift(nil, _, _, state), do: {nil, state}
  defp lift(cid, level, level, state), do: {cid, state}

  defp lift(cid, level, target, state) when level < target do
    {cid, state} = store(cid, [], state)
    lift(cid, level + 1, target, state)
  end

  defp normalize(nil, _, state), do: store_empty(state)

  defp normalize(cid, level, state) do
    {node, state} = read(cid, nil, nil, level, false, state)
    if node.entries == [], do: normalize(node.left, level - 1, state), else: {cid, state}
  end

  defp read(cid, low, high, level, root?, state) do
    {bytes, state} =
      case Map.fetch(state.created, cid) do
        {:ok, bytes} ->
          {bytes, state}

        :error ->
          case Map.fetch(state.fetched, cid) do
            {:ok, bytes} ->
              {bytes, state}

            :error ->
              case state.reader.(cid) do
                {:ok, bytes} when is_binary(bytes) -> {bytes, retain(state, :fetched, cid, bytes)}
                _ -> fail!(:invalid_mst_edit)
              end
          end
      end

    case MST.Node.decode(cid, bytes, low, high, level, root?) do
      {:ok, node} ->
        entries =
          Enum.map(node.entries, fn {key, value, child} -> {key, value, unlink(child)} end)

        {%{node | left: unlink(node.left), entries: entries}, state}

      _ ->
        fail!(:invalid_mst_edit)
    end
  end

  defp store(nil, [], state), do: {nil, state}

  defp store(left, entries, state) do
    if length(entries) > 10_000, do: fail!(:mst_edit_too_large)

    {entries, _} =
      Enum.map_reduce(entries, "", fn {key, cid, right}, previous ->
        p = common(previous, key, 0)

        {%{
           "p" => p,
           "k" => %Bytes{data: binary_part(key, p, byte_size(key) - p)},
           "v" => link(cid),
           "t" => link(right)
         }, key}
      end)

    save(CBOR.encode!(%{"l" => link(left), "e" => entries}), state)
  end

  defp store_empty(state), do: save(CBOR.encode!(%{"l" => nil, "e" => []}), state)

  defp save(bytes, state) do
    cid = CID.create(bytes, :dag_cbor)
    {cid, retain(state, :created, cid, bytes)}
  end

  defp retain(state, field, cid, bytes) do
    if byte_size(bytes) > 1_048_576, do: fail!(:mst_edit_too_large)

    if Map.has_key?(state.created, cid) or Map.has_key?(state.fetched, cid) do
      state
    else
      # Charge retained encoded bytes plus a fixed entry allowance for both maps.
      total = state.bytes + byte_size(bytes) + 128
      if total > state.limit, do: fail!(:mst_edit_too_large)

      state
      |> Map.put(field, Map.put(Map.fetch!(state, field), cid, bytes))
      |> Map.put(:bytes, total)
    end
  end

  defp common(<<c, a::binary>>, <<c, b::binary>>, n), do: common(a, b, n + 1)
  defp common(_, _, n), do: n
  defp unlink(nil), do: nil
  defp unlink(%Link{cid: cid}), do: cid
  defp link(nil), do: nil
  defp link(cid), do: %Link{cid: cid}
  defp fail!(reason), do: throw({:mst_editor, reason})
end
