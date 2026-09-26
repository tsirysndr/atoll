defmodule Atoll.Blobs.S3Listing do
  @moduledoc "Bounded S3 ListObjectsV2 XML parsing without dynamic atoms or external entities."

  def cursor?(nil), do: true

  def cursor?(value),
    do:
      is_binary(value) and byte_size(value) in 1..4096 and String.valid?(value) and
        not Regex.match?(~r/[\x00-\x1f\x7f]/u, value)

  def parse(xml, limit) when is_binary(xml) and byte_size(xml) <= 5 * 1024 * 1024 do
    with true <- String.valid?(xml) and not String.contains?(xml, ["<!", <<0>>]),
         {:ok, %{stack: [], root: root}, rest} <-
           :xmerl_sax_parser.stream(
             xml,
             [
               :disallow_entities,
               {:external_entities, :none},
               {:event_fun, &event/3},
               {:event_state, %{stack: [], root: nil, nodes: 0}}
             ]
           ),
         true <- String.trim(to_string(rest)) == "",
         "ListBucketResult" <- root.name,
         "url" <- scalar(root, "EncodingType"),
         truncated when truncated in ["true", "false"] <- scalar(root, "IsTruncated") do
      contents = children(root, "Contents")
      if length(contents) > limit, do: throw(:invalid_listing)
      objects = Enum.map(contents, &object/1)
      if length(Enum.uniq_by(objects, & &1.key)) != length(objects), do: throw(:invalid_listing)
      cursor = scalar(root, "NextContinuationToken", false)

      if not cursor?(cursor) or (truncated == "true" and is_nil(cursor)) or
           (truncated == "false" and not is_nil(cursor)),
         do: throw(:invalid_listing)

      {:ok, %{objects: objects, cursor: cursor}}
    else
      _ -> {:error, :invalid_s3_listing}
    end
  rescue
    _ -> {:error, :invalid_s3_listing}
  catch
    _ -> {:error, :invalid_s3_listing}
  end

  def parse(_, _), do: {:error, :invalid_s3_listing}

  defp object(node) do
    encoded = scalar(node, "Key")
    if Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, encoded), do: throw(:invalid_listing)
    key = URI.decode(encoded)

    unless String.valid?(key) and byte_size(key) <= 1024 and String.starts_with?(key, "blobs/"),
      do: throw(:invalid_listing)

    {size, ""} = Integer.parse(scalar(node, "Size"))
    unless size in 0..9_223_372_036_854_775_807, do: throw(:invalid_listing)
    {:ok, modified, 0} = DateTime.from_iso8601(scalar(node, "LastModified"))
    %{key: key, size: size, lastModified: DateTime.to_iso8601(modified)}
  end

  defp children(node, name), do: Enum.filter(node.children, &(&1.name == name))

  defp scalar(node, name, required \\ true) do
    case children(node, name) do
      [%{children: [], text: text}] -> text
      [] when not required -> nil
      _ -> throw(:invalid_listing)
    end
  end

  defp event({:startElement, uri, name, _, _}, _, state) do
    unless uri in [~c"", ~c"http://s3.amazonaws.com/doc/2006-03-01/"] and length(state.stack) < 8 and
             state.nodes < 20_000,
           do: throw(:invalid_listing)

    node = %{name: to_string(name), text: "", children: []}
    %{state | stack: [node | state.stack], nodes: state.nodes + 1}
  end

  defp event({:endElement, _, _, _}, _, %{stack: [node | rest]} = state) do
    node = %{node | children: Enum.reverse(node.children)}

    case rest do
      [] ->
        if state.root, do: throw(:invalid_listing)
        %{state | stack: [], root: node}

      [parent | ancestors] ->
        %{state | stack: [%{parent | children: [node | parent.children]} | ancestors]}
    end
  end

  defp event({:characters, chars}, _, %{stack: [node | rest]} = state) do
    text = node.text <> to_string(chars)
    if byte_size(text) > 16_384, do: throw(:invalid_listing)
    %{state | stack: [%{node | text: text} | rest]}
  end

  defp event({:startDTD, _, _, _}, _, _), do: throw(:invalid_listing)
  defp event(_, _, state), do: state
end
