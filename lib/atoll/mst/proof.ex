defmodule Atoll.MST.Proof do
  @moduledoc "Verifies a bounded MST search path against a caller-authenticated root, without requiring sibling subtrees."
  alias Atoll.{CBOR, CID, MST, Syntax}
  alias Atoll.CBOR.{Bytes, Link}

  def verify(root, key, blocks) when is_map(blocks) do
    if Syntax.repo_path?(key) do
      try do
        {:ok, walk(root, key, blocks, nil, nil, nil, 0)}
      catch
        :invalid_mst_proof -> {:error, :invalid_mst_proof}
      end
    else
      {:error, :invalid_mst_proof}
    end
  end

  def verify(_, _, _), do: {:error, :invalid_mst_proof}

  defp walk(cid, key, blocks, low, high, expected_level, depth) do
    if depth > 128, do: invalid!()
    bytes = Map.get(blocks, cid)

    unless dag?(cid) and is_binary(bytes) and byte_size(bytes) <= 1_048_576 and
             CID.verify(cid, bytes) == :ok,
           do: invalid!()

    with {:ok, %{"l" => left, "e" => entries} = node} <- CBOR.decode(bytes),
         true <- map_size(node) == 2 and is_list(entries) and length(entries) <= 10_000,
         true <- CBOR.encode!(node) == bytes and child?(left) do
      {entries, level} = entries(entries, low, high, expected_level)

      cond do
        entries == [] and depth == 0 ->
          if left != nil, do: invalid!()
          nil

        entries == [] ->
          if left == nil or not is_integer(level) or level < 0, do: invalid!()
          descend(left, key, blocks, low, high, level, depth)

        true ->
          search(entries, left, key, blocks, low, high, level, depth)
      end
    else
      _ -> invalid!()
    end
  end

  defp entries(entries, low, high, expected) do
    {decoded, _, level} =
      Enum.reduce(entries, {[], "", expected}, fn entry, {acc, previous, level} ->
        case entry do
          %{"p" => prefix, "k" => %Bytes{data: suffix}, "v" => %Link{cid: value}, "t" => right}
          when map_size(entry) == 4 and is_integer(prefix) and prefix >= 0 and
                 prefix <= byte_size(previous) ->
            current = binary_part(previous, 0, prefix) <> suffix
            height = MST.height(current)

            unless Syntax.repo_path?(current) and current > previous and
                     (is_nil(low) or current > low) and (is_nil(high) or current < high) and
                     prefix == common(previous, current, 0) and dag?(value) and child?(right) and
                     (is_nil(level) or level == height),
                   do: invalid!()

            {[{current, value, right} | acc], current, height}

          _ ->
            invalid!()
        end
      end)

    {Enum.reverse(decoded), level}
  end

  defp search([], child, key, blocks, low, high, level, depth),
    do: descend(child, key, blocks, low, high, level, depth)

  defp search([{current, value, right} | rest], left, key, blocks, low, high, level, depth) do
    cond do
      key == current -> value
      key < current -> descend(left, key, blocks, low, current, level, depth)
      true -> search(rest, right, key, blocks, current, high, level, depth)
    end
  end

  defp descend(nil, _, _, _, _, _, _), do: nil

  defp descend(%Link{cid: cid}, key, blocks, low, high, level, depth),
    do: walk(cid, key, blocks, low, high, level - 1, depth + 1)

  defp child?(nil), do: true
  defp child?(%Link{cid: cid}), do: dag?(cid)
  defp child?(_), do: false
  defp dag?(cid) when is_binary(cid), do: match?({:ok, %{codec: :dag_cbor}}, CID.decode(cid))
  defp dag?(_), do: false
  defp common(<<c, a::binary>>, <<c, b::binary>>, n), do: common(a, b, n + 1)
  defp common(_, _, n), do: n
  defp invalid!, do: throw(:invalid_mst_proof)
end
