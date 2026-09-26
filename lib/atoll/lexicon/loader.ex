defmodule Atoll.Lexicon.Loader do
  @moduledoc "Loads bounded operator-trusted record Lexicons; performs no network discovery."
  alias Atoll.Syntax

  @fields %{
    "record" => ~w(key record),
    "object" => ~w(properties required nullable),
    "array" => ~w(items minLength maxLength),
    "ref" => ~w(ref),
    "union" => ~w(refs closed),
    "blob" => ~w(accept maxSize),
    "string" =>
      ~w(format minLength maxLength minGraphemes maxGraphemes knownValues enum const default),
    "integer" => ~w(minimum maximum enum const default),
    "boolean" => ~w(const default),
    "bytes" => ~w(minLength maxLength),
    "cid-link" => [],
    "unknown" => [],
    "token" => []
  }
  @formats ~w(at-uri at-identifier did handle nsid record-key cid tid datetime uri language)

  def load!(directory) when is_binary(directory) and directory != "" do
    unless File.dir?(directory), do: invalid!("directory does not exist")
    files = Path.wildcard(Path.join(directory, "*.json"))
    unless length(files) <= 128, do: invalid!("more than 128 files")

    {documents, _size} =
      Enum.map_reduce(files, 0, fn file, total ->
        unless match?({:ok, %{type: :regular}}, File.lstat(file)),
          do: invalid!("expected regular JSON files")

        bytes = File.open!(file, [:read, :binary], &IO.binread(&1, 262_145))

        unless is_binary(bytes) and byte_size(bytes) <= 262_144 and
                 total + byte_size(bytes) <= 8_388_608,
               do: invalid!("file or catalog size limit exceeded")

        doc = bytes |> Jason.decode!(objects: :ordered_objects) |> unique_object!()
        {doc, total + byte_size(bytes)}
      end)

    validate!(documents)
  rescue
    error in [File.Error, Jason.DecodeError] ->
      raise ArgumentError, "Cannot load custom Lexicons: #{Exception.message(error)}"
  end

  def load!(_), do: invalid!("expected a directory path")

  def validate!(documents) when is_list(documents) and length(documents) <= 128 do
    builtins = Atoll.Lexicon.Schema.builtin_documents()

    custom =
      Enum.reduce(documents, %{}, fn doc, acc ->
        unless document?(doc), do: invalid!("malformed or unsupported document")
        id = doc["id"]

        if Map.has_key?(acc, id) or Map.has_key?(builtins, id),
          do: invalid!("duplicate or bundled NSID #{id}")

        Map.put(acc, id, doc)
      end)

    catalog = Map.merge(builtins, custom)

    queue = for {id, doc} <- custom, {ref, union?} <- references(doc), do: {id, ref, union?}
    validate_references!(queue, catalog, MapSet.new())

    custom
  end

  def validate!(_), do: invalid!("expected at most 128 documents")

  defp validate_references!([], _, _), do: :ok

  defp validate_references!([{id, ref, union?} | rest], catalog, seen) do
    [nsid | fragments] =
      String.split(if(String.starts_with?(ref, "#"), do: id <> ref, else: ref), "#")

    name =
      case fragments do
        [] -> "main"
        [name] -> name
        _ -> nil
      end

    target = get_in(catalog, [nsid, "defs", name])

    unless is_map(target) and node?(target, 0) and
             target["type"] not in ["ref", "union", "unknown", "token"] and
             (not union? or target["type"] in ["object", "record"]),
           do: invalid!("unresolved or invalid reference in #{id}")

    if MapSet.member?(seen, {nsid, name}) do
      validate_references!(rest, catalog, seen)
    else
      children = for {child, union?} <- references(target), do: {nsid, child, union?}
      validate_references!(children ++ rest, catalog, MapSet.put(seen, {nsid, name}))
    end
  end

  defp document?(%{"lexicon" => 1, "id" => id, "defs" => defs} = doc)
       when is_map(defs) and map_size(defs) > 0 do
    Syntax.nsid?(id) and keys?(doc, ~w(lexicon id defs description)) and
      Enum.all?(defs, fn {name, schema} ->
        name?(name) and is_map(schema) and schema["type"] not in ["ref", "union", "unknown"] and
          (schema["type"] != "record" or name == "main") and node?(schema, 0)
      end)
  end

  defp document?(_), do: false

  defp node?(%{"type" => type} = schema, depth) when depth <= 32 do
    Map.has_key?(@fields, type) and keys?(schema, ["type", "description" | @fields[type]]) and
      constraints?(schema) and shape?(schema, depth)
  end

  defp node?(_, _), do: false

  defp shape?(
         %{"type" => "record", "key" => key, "record" => %{"type" => "object"} = body},
         depth
       ),
       do: record_key?(key) and node?(body, depth + 1)

  defp shape?(%{"type" => "object", "properties" => properties} = schema, depth)
       when is_map(properties) do
    Enum.all?(properties, fn {key, child} ->
      is_binary(key) and key != "" and node?(child, depth + 1) and
        child["type"] not in ["record", "token"]
    end) and
      Enum.all?(["required", "nullable"], fn field ->
        values = Map.get(schema, field, [])

        is_list(values) and Enum.all?(values, &Map.has_key?(properties, &1)) and
          Enum.uniq(values) == values
      end)
  end

  defp shape?(%{"type" => "array", "items" => child}, depth),
    do: node?(child, depth + 1) and child["type"] not in ["record", "token"]

  defp shape?(%{"type" => "ref", "ref" => ref}, _), do: reference?(ref)

  defp shape?(%{"type" => "union", "refs" => refs} = schema, _),
    do:
      is_list(refs) and Enum.all?(refs, &reference?/1) and
        is_boolean(Map.get(schema, "closed", false)) and (refs != [] or schema["closed"] != true)

  defp shape?(%{"type" => "blob"} = schema, _),
    do:
      not Map.has_key?(schema, "accept") or
        (is_list(schema["accept"]) and Enum.all?(schema["accept"], &mime?/1))

  defp shape?(%{"type" => type}, _),
    do: type in ~w(string integer boolean bytes cid-link unknown token)

  defp constraints?(schema) do
    Enum.all?(~w(minLength maxLength minGraphemes maxGraphemes maxSize), fn key ->
      not Map.has_key?(schema, key) or (is_integer(schema[key]) and schema[key] >= 0)
    end) and
      Enum.all?(~w(minimum maximum), fn key ->
        not Map.has_key?(schema, key) or integer?(schema[key])
      end) and
      Enum.all?(
        [{"minimum", "maximum"}, {"minLength", "maxLength"}, {"minGraphemes", "maxGraphemes"}],
        fn {low, high} ->
          not (Map.has_key?(schema, low) and Map.has_key?(schema, high)) or
            schema[low] <= schema[high]
        end
      ) and
      (not Map.has_key?(schema, "format") or schema["format"] in @formats) and
      not (Map.has_key?(schema, "const") and Map.has_key?(schema, "default")) and
      Enum.all?(~w(const default), fn key ->
        not Map.has_key?(schema, key) or
          (primitive?(schema[key], schema["type"]) and
             Atoll.Lexicon.Schema.literal_valid?(schema[key], schema))
      end) and
      Enum.all?(~w(enum knownValues), fn key ->
        not Map.has_key?(schema, key) or
          (is_list(schema[key]) and Enum.all?(schema[key], &primitive?(&1, schema["type"])))
      end)
  end

  defp primitive?(value, "string"), do: is_binary(value)
  defp primitive?(value, "integer"), do: integer?(value)
  defp primitive?(value, "boolean"), do: is_boolean(value)
  defp primitive?(_, _), do: false

  defp integer?(value),
    do:
      is_integer(value) and value >= -9_223_372_036_854_775_808 and
        value <= 9_223_372_036_854_775_807

  defp keys?(map, allowed), do: Enum.all?(Map.keys(map), &(&1 in allowed))
  defp name?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Za-z][A-Za-z0-9]*\z/, value)
  defp record_key?("literal:" <> key), do: Syntax.record_key?(key)
  defp record_key?(key), do: key in ["tid", "any"]

  defp reference?(value) when is_binary(value) do
    case String.split(value, "#") do
      [nsid] -> Syntax.nsid?(nsid)
      [nsid, name] -> (nsid == "" or Syntax.nsid?(nsid)) and name?(name)
      _ -> false
    end
  end

  defp reference?(_), do: false

  defp mime?(value),
    do:
      is_binary(value) and
        Regex.match?(~r{\A(?:\*/\*|[a-z0-9!#$&^_.+-]+/(?:\*|[a-z0-9!#$&^_.+-]+))\z}, value)

  defp references(%{"type" => "ref", "ref" => ref}), do: [{ref, false}]
  defp references(%{"type" => "union", "refs" => refs}), do: Enum.map(refs, &{&1, true})

  defp references(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&references/1)

  defp references(value) when is_list(value), do: Enum.flat_map(value, &references/1)
  defp references(_), do: []

  defp unique_object!(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))
    unless Enum.uniq(keys) == keys, do: invalid!("duplicate JSON object keys")
    Map.new(values, fn {key, value} -> {key, unique_object!(value)} end)
  end

  defp unique_object!(value) when is_list(value), do: Enum.map(value, &unique_object!/1)
  defp unique_object!(value), do: value

  defp invalid!(reason),
    do: raise(ArgumentError, "Invalid custom Lexicon configuration: #{reason}")
end
