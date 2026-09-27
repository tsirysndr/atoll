defmodule Atoll.MST.Builder do
  @moduledoc """
  Builds a canonical MST from strictly increasing {path, CID} entries in one pass.
  Emits completed nodes immediately through a writer returning :ok. Retains only
  pending ancestor entries, bounded by an accounting budget, not a whole tree.
  Emission is not atomic: callers must stage writes or use a transaction.
  """
  alias Atoll.{CBOR, CID, MST, Syntax}
  alias Atoll.CBOR.{Bytes, Link}

  def build(records, writer, opts \\ []) when is_function(writer, 2) do
    limits = %{
      bytes: Keyword.get(opts, :max_pending_bytes, 16 * 1024 * 1024),
      nodes: Keyword.get(opts, :max_nodes, 100_000),
      records: Keyword.get(opts, :max_records, 1_000_000)
    }

    unless Enum.all?(limits, fn {_, n} -> is_integer(n) and n > 0 end),
      do: raise(ArgumentError, "MST builder limits must be positive integers")

    state = %{
      stack: [],
      previous: nil,
      bytes: 0,
      nodes: 0,
      records: 0,
      writer: writer,
      limits: limits
    }

    try do
      state = Enum.reduce(records, state, &insert/2)
      {state, root} = close_below(state, 129, nil)

      case root do
        nil ->
          {cid, _state} = emit(state, nil, [])
          {:ok, cid}

        {cid, _height} ->
          {:ok, cid}
      end
    catch
      {:mst_builder, reason} -> {:error, reason}
    end
  end

  defp insert({path, cid}, state) do
    unless Syntax.repo_path?(path) and MST.Node.dag?(cid) and
             (is_nil(state.previous) or path > state.previous),
           do: fail!(:invalid_mst)

    if state.records >= state.limits.records, do: fail!(:mst_too_large)
    height = MST.height(path)
    {state, child} = close_below(state, height, nil)

    {frame, state} =
      case state.stack do
        [%{height: ^height} = frame | rest] ->
          {frame, state} = attach(frame, child, %{state | stack: rest})
          {frame, state}

        _ ->
          {left, state} = lift(child, height - 1, state)
          {%{height: height, left: left, entries: [], previous: "", bytes: 0, count: 0}, state}
      end

    charge = byte_size(path) + 128

    if state.bytes + charge > state.limits.bytes or frame.count >= 10_000,
      do: fail!(:mst_too_large)

    prefix = common(frame.previous, path, 0)

    entry = %{
      "p" => prefix,
      "k" => %Bytes{data: binary_part(path, prefix, byte_size(path) - prefix)},
      "v" => link(cid),
      "t" => nil
    }

    frame = %{
      frame
      | entries: [entry | frame.entries],
        previous: path,
        bytes: frame.bytes + charge,
        count: frame.count + 1
    }

    %{
      state
      | stack: [frame | state.stack],
        previous: path,
        bytes: state.bytes + charge,
        records: state.records + 1
    }
  end

  defp insert(_, _), do: fail!(:invalid_mst)

  defp close_below(%{stack: [frame | rest]} = state, height, child) when frame.height < height do
    {frame, state} = attach(frame, child, %{state | stack: rest})
    {cid, state} = emit(state, frame.left, Enum.reverse(frame.entries))
    state = %{state | bytes: state.bytes - frame.bytes}
    close_below(state, height, {cid, frame.height})
  end

  defp close_below(state, _, child), do: {state, child}

  defp attach(frame, nil, state), do: {frame, state}

  defp attach(frame, child, state) do
    {cid, state} = lift(child, frame.height - 1, state)
    [entry | rest] = frame.entries
    {%{frame | entries: [Map.put(entry, "t", link(cid)) | rest]}, state}
  end

  defp lift(nil, _, state), do: {nil, state}
  defp lift({cid, height}, height, state), do: {cid, state}

  defp lift({cid, height}, target, state) when height < target do
    {parent, state} = emit(state, cid, [])
    lift({parent, height + 1}, target, state)
  end

  defp emit(state, left, entries) do
    if state.nodes >= state.limits.nodes, do: fail!(:mst_too_large)
    bytes = CBOR.encode!(%{"l" => link(left), "e" => entries})
    if byte_size(bytes) > 1_048_576, do: fail!(:mst_too_large)
    cid = CID.create(bytes, :dag_cbor)
    unless state.writer.(cid, bytes) == :ok, do: fail!(:mst_write_failed)
    {cid, %{state | nodes: state.nodes + 1}}
  end

  defp common(<<c, a::binary>>, <<c, b::binary>>, n), do: common(a, b, n + 1)
  defp common(_, _, n), do: n
  defp link(nil), do: nil
  defp link(cid), do: %Link{cid: cid}
  defp fail!(reason), do: throw({:mst_builder, reason})
end
