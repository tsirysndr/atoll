defmodule Atoll.DataModel do
  @moduledoc "Converts decoded ATProto JSON values to and from the CBOR data model."

  alias Atoll.CID
  alias Atoll.CBOR.{Bytes, Link}

  @spec from_json(term()) :: {:ok, term()} | {:error, :invalid_data}
  def from_json(value), do: convert(value, :from)

  @spec to_json(term()) :: {:ok, term()} | {:error, :invalid_data}
  def to_json(value), do: convert(value, :to)

  defp convert(value, direction) do
    {:ok, walk(value, direction, 0)}
  catch
    :invalid_data -> {:error, :invalid_data}
  end

  defp walk(value, _, _) when value in [nil, true, false], do: value

  defp walk(value, _, _)
       when is_integer(value) and value >= -9_223_372_036_854_775_808 and
              value <= 9_223_372_036_854_775_807,
       do: value

  defp walk(value, _, _) when is_binary(value) do
    if String.valid?(value), do: value, else: invalid!()
  end

  defp walk(%Link{cid: cid}, :to, _) when is_binary(cid) do
    case CID.decode(cid) do
      {:ok, _} -> %{"$link" => CID.to_base32(cid)}
      _ -> invalid!()
    end
  end

  defp walk(%Bytes{data: data}, :to, _) when is_binary(data),
    do: %{"$bytes" => Base.encode64(data)}

  defp walk(%{"$link" => text} = value, :from, _) when map_size(value) == 1 do
    case CID.from_base32(text) do
      {:ok, cid} -> %Link{cid: cid}
      _ -> invalid!()
    end
  end

  defp walk(%{"$bytes" => text} = value, :from, _)
       when map_size(value) == 1 and is_binary(text) do
    # ATProto accepts both padded and unpadded standard base64.
    case Base.decode64(text, padding: false) do
      {:ok, data} -> %Bytes{data: data}
      _ -> invalid!()
    end
  end

  defp walk(value, direction, depth) when is_list(value) and depth < 64 do
    Enum.map(value, &walk(&1, direction, depth + 1))
  end

  defp walk(value, direction, depth)
       when is_map(value) and not is_struct(value) and depth < 64 do
    if Map.has_key?(value, "$link") or Map.has_key?(value, "$bytes"), do: invalid!()

    Map.new(value, fn {key, item} ->
      unless is_binary(key) and String.valid?(key), do: invalid!()
      {key, walk(item, direction, depth + 1)}
    end)
  end

  defp walk(_, _, _), do: invalid!()
  defp invalid!, do: throw(:invalid_data)
end
