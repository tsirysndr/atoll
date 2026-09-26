defmodule Atoll.Lexicon.Query do
  @moduledoc "Bounded XRPC query decoding and validation against vendored query Lexicons."
  alias Atoll.{CID, Syntax, TID}

  @files Path.wildcard(Path.expand("../../../priv/lexicons/*.json", __DIR__))
  for file <- @files, do: @external_resource(file)

  @schemas Map.new(@files, fn file ->
             doc = file |> File.read!() |> Jason.decode!()
             {doc["id"], get_in(doc, ["defs", "main", "parameters"]) || %{}}
           end)

  def methods, do: Map.keys(@schemas)

  def decode(nsid, query) when is_binary(query) and byte_size(query) <= 32_768 do
    with {:ok, schema} <- Map.fetch(@schemas, nsid),
         true <- String.valid?(query) and not Regex.match?(~r/%(?![0-9a-fA-F]{2})/, query),
         pairs = query |> URI.query_decoder() |> Enum.take(257),
         true <- length(pairs) <= 256,
         {:ok, params} <- collect(pairs, schema["properties"] || %{}),
         true <- Enum.all?(schema["required"] || [], &Map.has_key?(params, &1)),
         true <- valid_params?(params, schema["properties"] || %{}) do
      {:ok, params}
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    ArgumentError -> {:error, :invalid_request}
  end

  def decode(_, _), do: {:error, :invalid_request}

  defp collect(pairs, properties) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      # Retain the pre-existing cids[] alias, but only for declared array fields.
      base = String.replace_suffix(key, "[]", "")
      array? = match?(%{"type" => "array"}, properties[base])
      key = if array?, do: base, else: key

      cond do
        not String.valid?(key) or not String.valid?(value) ->
          {:halt, {:error, :invalid_request}}

        String.contains?(key, ["[", "]"]) ->
          {:halt, {:error, :invalid_request}}

        array? ->
          {:cont, {:ok, Map.update(acc, key, [value], &[value | &1])}}

        Map.has_key?(acc, key) ->
          {:halt, {:error, :invalid_request}}

        true ->
          {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
    |> case do
      {:ok, params} ->
        {:ok, Map.new(params, fn {k, v} -> {k, if(is_list(v), do: Enum.reverse(v), else: v)} end)}

      error ->
        error
    end
  end

  defp valid_params?(params, properties) do
    Enum.all?(properties, fn {name, schema} ->
      not Map.has_key?(params, name) or valid?(params[name], schema)
    end)
  end

  defp valid?(values, %{"type" => "array", "items" => items} = schema) when is_list(values),
    do:
      bounds?(length(values), schema, "minLength", "maxLength") and
        Enum.all?(values, &valid?(&1, items))

  defp valid?(value, %{"type" => "boolean"}), do: value in ["true", "false"]

  defp valid?(value, %{"type" => "integer"} = schema) when is_binary(value) do
    with true <- Regex.match?(~r/\A-?[0-9]{1,16}\z/, value),
         {integer, ""} <- Integer.parse(value) do
      abs(integer) <= 9_007_199_254_740_991 and bounds?(integer, schema, "minimum", "maximum")
    else
      _ -> false
    end
  end

  defp valid?(value, %{"type" => "string"} = schema) when is_binary(value) do
    bounds?(byte_size(value), schema, "minLength", "maxLength") and
      (is_nil(schema["enum"]) or value in schema["enum"]) and format?(value, schema["format"])
  end

  defp valid?(_, _), do: false

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
  defp format?(value, "tid"), do: TID.valid?(value)
  defp format?(value, "cid"), do: match?({:ok, _}, CID.from_base32(value))
  defp format?(_, _), do: false
end
