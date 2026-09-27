defmodule Atoll.MST.Node do
  @moduledoc "Canonical MST node validation within inherited key and level bounds."
  alias Atoll.{CBOR, CID, MST, Syntax}
  alias Atoll.CBOR.{Bytes, Link}

  def decode(cid, bytes, low, high, expected, root?) do
    try do
      unless dag?(cid) and is_binary(bytes) and byte_size(bytes) <= 1_048_576 and
               CID.verify(cid, bytes) == :ok,
             do: invalid!()

      with {:ok, %{"l" => left, "e" => entries} = node} <- CBOR.decode(bytes),
           true <- map_size(node) == 2 and is_list(entries) and length(entries) <= 10_000,
           true <- CBOR.encode!(node) == bytes and child?(left) do
        {entries, level} = entries(entries, low, high, expected)

        if entries == [] do
          if root? do
            if left != nil, do: invalid!()
          else
            if left == nil or not is_integer(level) or level < 0, do: invalid!()
          end
        end

        {:ok, %{left: left, entries: entries, level: level}}
      else
        _ -> invalid!()
      end
    catch
      :invalid_mst_node -> {:error, :invalid_mst_node}
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

  def dag?(cid) when is_binary(cid), do: match?({:ok, %{codec: :dag_cbor}}, CID.decode(cid))
  def dag?(_), do: false
  defp child?(nil), do: true
  defp child?(%Link{cid: cid}), do: dag?(cid)
  defp child?(_), do: false
  defp common(<<c, a::binary>>, <<c, b::binary>>, n), do: common(a, b, n + 1)
  defp common(_, _, n), do: n
  defp invalid!, do: throw(:invalid_mst_node)
end
