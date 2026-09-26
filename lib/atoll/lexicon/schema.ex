defmodule Atoll.Lexicon.Schema do
  @moduledoc "Shared validator for pinned procedure envelopes and supported record Lexicons."
  alias Atoll.{CID, Syntax, TID}

  @glob Path.expand("../../../priv/lexicons/*.json", __DIR__)
  @files Path.wildcard(@glob)
  for file <- @files, do: @external_resource(file)

  @documents @files
             |> Enum.map(fn file -> file |> File.read!() |> Jason.decode!() end)
             |> Map.new(&{&1["id"], &1})

  @doc false
  def __mix_recompile__?, do: Path.wildcard(@glob) != @files

  @doc "Built-in record collection NSIDs at this pinned schema revision."
  def record_collections do
    for {nsid, doc} <- @documents, get_in(doc, ["defs", "main", "type"]) == "record", do: nsid
  end

  def methods do
    for {nsid, doc} <- @documents, get_in(doc, ["defs", "main", "type"]) == "procedure", do: nsid
  end

  def record(collection, rkey, value, mode) when mode in [true, false, :optimistic] do
    if mode == false do
      {:ok, "unknown"}
    else
      case get_in(@documents, [collection, "defs", "main"]) do
        %{"type" => "record", "key" => key, "record" => schema} ->
          if record_key?(rkey, key) and is_map(value) and value["$type"] == collection and
               valid?(value, schema, @documents[collection], 0),
             do: {:ok, "valid"},
             else: {:error, :invalid_record_schema}

        _ when mode == :optimistic ->
          {:ok, "unknown"}

        _ ->
          {:error, :validation_unavailable}
      end
    end
  end

  def record(_, _, _, _), do: {:error, :invalid_request}
  defp record_key?(nil, "tid"), do: true
  defp record_key?(key, "tid"), do: TID.valid?(key)
  defp record_key?(key, "literal:" <> literal), do: key == literal
  defp record_key?(key, "any"), do: is_nil(key) or Syntax.record_key?(key)
  defp record_key?(_, _), do: false

  def validate(nsid, body) do
    case @documents[nsid] do
      %{
        "defs" => %{
          "main" => %{"input" => %{"encoding" => "application/json", "schema" => schema}}
        }
      } = doc ->
        if is_map(body) and not Map.has_key?(body, "_json") and valid?(body, schema, doc, 0),
          do: :ok,
          else: {:error, :invalid_request}

      nil ->
        {:error, :invalid_request}

      _ ->
        :ok
    end
  end

  defp valid?(_, _, _, depth) when depth > 32, do: false

  defp valid?(value, %{"type" => "object"} = schema, doc, depth) when is_map(value) do
    properties = schema["properties"] || %{}
    required = schema["required"] || []
    nullable = schema["nullable"] || []

    Enum.all?(required, fn key ->
      Map.has_key?(value, key) or Map.has_key?(properties[key] || %{}, "default")
    end) and
      Enum.all?(properties, fn {key, child} ->
        case Map.fetch(value, key) do
          :error -> true
          {:ok, nil} -> key in nullable
          {:ok, item} -> valid?(item, child, doc, depth + 1)
        end
      end)
  end

  defp valid?(value, %{"type" => "array", "items" => items} = schema, doc, depth)
       when is_list(value) do
    bounds?(length(value), schema, "minLength", "maxLength") and
      Enum.all?(value, &valid?(&1, items, doc, depth + 1))
  end

  defp valid?(
         %{"$type" => type} = value,
         %{"type" => "union", "refs" => refs} = schema,
         doc,
         depth
       )
       when is_binary(type) do
    case Enum.find(refs, &(absolute_ref(&1, doc) == type)) do
      nil -> schema["closed"] != true and union_tag?(type)
      ref -> valid?(value, %{"type" => "ref", "ref" => ref}, doc, depth + 1)
    end
  end

  defp valid?(value, %{"type" => "ref", "ref" => ref}, doc, depth) do
    [nsid | fragments] = String.split(absolute_ref(ref, doc), "#")

    name =
      case fragments do
        [] -> "main"
        [name] -> name
        _ -> nil
      end

    case get_in(@documents, [nsid, "defs", name]) do
      nil -> false
      schema -> valid?(value, schema, @documents[nsid], depth + 1)
    end
  end

  defp valid?(value, %{"type" => "boolean"}, _, _), do: is_boolean(value)

  defp valid?(value, %{"type" => "integer"} = schema, _, _) do
    is_integer(value) and abs(value) <= 9_007_199_254_740_991 and
      bounds?(value, schema, "minimum", "maximum")
  end

  defp valid?(value, %{"type" => "string"} = schema, _, _) when is_binary(value) do
    String.valid?(value) and bounds?(byte_size(value), schema, "minLength", "maxLength") and
      bounds?(String.length(value), schema, "minGraphemes", "maxGraphemes") and
      (is_nil(schema["enum"]) or value in schema["enum"]) and format?(value, schema["format"])
  end

  defp valid?(
         %{
           "$type" => "blob",
           "ref" => %{"$link" => cid} = ref,
           "mimeType" => mime,
           "size" => size
         },
         %{"type" => "blob"} = schema,
         _,
         _
       ) do
    with true <- map_size(ref) == 1 and is_integer(size) and size >= 0,
         true <- is_nil(schema["maxSize"]) or size <= schema["maxSize"],
         true <- is_binary(mime),
         {:ok, type, subtype, params} <- Plug.Conn.Utils.media_type(mime),
         true <- map_size(params) == 0,
         {:ok, decoded} <- CID.from_base32(cid),
         {:ok, %{codec: :raw}} <- CID.decode(decoded) do
      accepted = schema["accept"] || ["*/*"]
      Enum.any?(accepted, &(&1 in ["*/*", type <> "/*", type <> "/" <> subtype]))
    else
      _ -> false
    end
  end

  # "unknown" in these procedure envelopes is record/plcOp data, not a promise
  # that its application Lexicon or signatures have been checked here.
  defp valid?(value, %{"type" => "unknown"}, _, _) do
    is_map(value) and not is_struct(value) and value["$type"] != "blob" and
      not Map.has_key?(value, "$link") and not Map.has_key?(value, "$bytes")
  end

  defp valid?(_, _, _, _), do: false

  defp union_tag?(type) do
    case String.split(type, "#") do
      [nsid] -> Syntax.nsid?(nsid)
      [nsid, name] -> Syntax.nsid?(nsid) and Regex.match?(~r/\A[a-zA-Z][a-zA-Z0-9]*\z/, name)
      _ -> false
    end
  end

  defp absolute_ref("#" <> _ = ref, doc), do: doc["id"] <> ref
  defp absolute_ref(ref, _), do: ref

  defp bounds?(value, schema, low, high),
    do:
      (is_nil(schema[low]) or value >= schema[low]) and
        (is_nil(schema[high]) or value <= schema[high])

  defp format?(_, nil), do: true
  defp format?(value, "language"), do: Atoll.Lexicon.Language.valid?(value)

  defp format?(value, "uri") do
    byte_size(value) <= 8192 and
      Regex.match?(~r/\A[A-Za-z][A-Za-z0-9+.-]*:[A-Za-z0-9._~:!$&'()*+,;=\/@?%#\[\]-]*\z/, value) and
      not Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, value) and match?({:ok, _}, URI.new(value))
  end

  defp format?(value, "at-uri"), do: Syntax.at_uri?(value)
  defp format?(value, "did"), do: Syntax.did?(value)
  defp format?(value, "handle"), do: Syntax.handle?(value)
  defp format?(value, "at-identifier"), do: Syntax.did?(value) or Syntax.handle?(value)
  defp format?(value, "nsid"), do: Syntax.nsid?(value)
  defp format?(value, "record-key"), do: Syntax.record_key?(value)
  defp format?(value, "cid"), do: match?({:ok, _}, CID.from_base32(value))

  defp format?(value, "datetime") do
    syntax? =
      Regex.match?(
        ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})\z/,
        value
      )

    if syntax? and not String.ends_with?(value, "-00:00") do
      case DateTime.from_iso8601(value) do
        {:ok, datetime, _offset} -> datetime.year >= 0
        _ -> false
      end
    else
      false
    end
  end

  defp format?(_, _), do: false
end
