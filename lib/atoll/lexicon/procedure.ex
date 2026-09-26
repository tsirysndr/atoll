defmodule Atoll.Lexicon.Procedure do
  @moduledoc "Validates JSON procedure envelopes; record data is validated separately by the repository."
  alias Atoll.{CID, Syntax}

  @files Path.wildcard(Path.expand("../../../priv/lexicons/*.json", __DIR__))
  for file <- @files, do: @external_resource(file)

  @documents @files
             |> Enum.map(fn file -> file |> File.read!() |> Jason.decode!() end)
             |> Enum.filter(&(get_in(&1, ["defs", "main", "type"]) == "procedure"))
             |> Map.new(&{&1["id"], &1})

  def methods, do: Map.keys(@documents)

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

  defp valid?(%{"$type" => type} = value, %{"type" => "union", "refs" => refs}, doc, depth)
       when is_binary(type) do
    case Enum.find(refs, &(absolute_ref(&1, doc) == type)) do
      nil -> false
      ref -> valid?(value, %{"type" => "ref", "ref" => ref}, doc, depth + 1)
    end
  end

  defp valid?(value, %{"type" => "ref", "ref" => "#" <> name}, doc, depth) do
    case doc["defs"][name] do
      nil -> false
      schema -> valid?(value, schema, doc, depth + 1)
    end
  end

  defp valid?(value, %{"type" => "boolean"}, _, _), do: is_boolean(value)

  defp valid?(value, %{"type" => "integer"} = schema, _, _) do
    is_integer(value) and abs(value) <= 9_007_199_254_740_991 and
      bounds?(value, schema, "minimum", "maximum")
  end

  defp valid?(value, %{"type" => "string"} = schema, _, _) when is_binary(value) do
    String.valid?(value) and bounds?(byte_size(value), schema, "minLength", "maxLength") and
      (is_nil(schema["enum"]) or value in schema["enum"]) and format?(value, schema["format"])
  end

  # "unknown" in these procedure envelopes is record/plcOp data, not a promise
  # that its application Lexicon or signatures have been checked here.
  defp valid?(value, %{"type" => "unknown"}, _, _) do
    is_map(value) and not is_struct(value) and value["$type"] != "blob" and
      not Map.has_key?(value, "$link") and not Map.has_key?(value, "$bytes")
  end

  defp valid?(_, _, _, _), do: false

  defp absolute_ref("#" <> _ = ref, doc), do: doc["id"] <> ref
  defp absolute_ref(ref, _), do: ref

  defp bounds?(value, schema, low, high),
    do:
      (is_nil(schema[low]) or value >= schema[low]) and
        (is_nil(schema[high]) or value <= schema[high])

  defp format?(_, nil), do: true
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
