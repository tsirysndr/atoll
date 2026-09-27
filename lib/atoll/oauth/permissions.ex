defmodule Atoll.OAuth.Permissions do
  @moduledoc "Bounded repository and blob permission scopes with semantic coverage."
  @legacy ~w(atproto transition:generic transition:chat.bsky transition:email)
  @actions ~w(create update delete)

  def supported?(scope),
    do: scope in @legacy or match?({:ok, _}, repo(scope)) or match?({:ok, _}, blob(scope))

  def repo(value) do
    with {:ok, positional, params} <- syntax(value, "repo", ~w(collection action)),
         true <- is_nil(positional) or not Map.has_key?(params, "collection"),
         collections = if(positional, do: [positional], else: params["collection"]),
         actions = Map.get(params, "action", @actions),
         true <- is_list(collections) and collections != [],
         true <- Enum.all?(collections, &(&1 == "*" or Atoll.Syntax.nsid?(&1))),
         true <- actions != [] and Enum.all?(actions, &(&1 in @actions)),
         true <- length(Enum.uniq(actions)) == length(actions) do
      {:ok, %{collections: Enum.uniq(collections), actions: actions}}
    else
      _ -> {:error, :invalid_scope}
    end
  end

  def blob(value) do
    with {:ok, positional, params} <- syntax(value, "blob", ["accept"]),
         true <- is_nil(positional) or not Map.has_key?(params, "accept"),
         accept = if(positional, do: [positional], else: params["accept"]),
         true <- is_list(accept) and accept != [],
         true <- Enum.all?(accept, &mime_pattern?/1) do
      {:ok, %{accept: accept |> Enum.map(&String.downcase/1) |> Enum.uniq()}}
    else
      _ -> {:error, :invalid_scope}
    end
  end

  # A requested permission can be narrower than several declared/granted scopes.
  # In particular, an explicit collection can never cover a requested wildcard.
  def covered?(granted, requested) when is_list(granted) do
    if requested in granted do
      true
    else
      case repo(requested) do
        {:ok, permission} ->
          Enum.all?(permission.collections, fn collection ->
            Enum.all?(permission.actions, &repo_allowed?(granted, collection, &1))
          end)

        _ ->
          case blob(requested) do
            {:ok, permission} -> Enum.all?(permission.accept, &blob_allowed?(granted, &1))
            _ -> false
          end
      end
    end
  end

  def write_admission?(scope, action) do
    scopes = String.split(scope, " ")

    "transition:generic" in scopes or
      case action do
        :upload_blob -> Enum.any?(scopes, &match?({:ok, _}, blob(&1)))
        :batch -> Enum.any?(scopes, &match?({:ok, _}, repo(&1)))
        :put -> Enum.all?(~w(create update), &any_action?(scopes, &1))
        :create -> any_action?(scopes, "create")
        :delete -> any_action?(scopes, "delete")
        _ -> false
      end
  end

  def allows_repo?(scope, collection, action) when action in @actions do
    scopes = String.split(scope, " ")
    "transition:generic" in scopes or repo_allowed?(scopes, collection, action)
  end

  def allows_blob?(scope, mime) do
    with {:ok, mime} <- Atoll.Blobs.normalize_mime(mime) do
      scopes = String.split(scope, " ")
      "transition:generic" in scopes or blob_allowed?(scopes, mime)
    else
      _ -> false
    end
  end

  def describe(scope) do
    case repo(scope) do
      {:ok, permission} ->
        collections =
          Enum.map_join(permission.collections, ", ", fn
            "*" -> "all collections"
            collection -> collection
          end)

        "Write public records: " <> Enum.join(permission.actions, ", ") <> " in " <> collections

      _ ->
        case blob(scope) do
          {:ok, permission} ->
            "Upload media: " <>
              Enum.map_join(permission.accept, ", ", fn
                "*/*" -> "all media types"
                mime -> mime
              end)

          _ ->
            nil
        end
    end
  end

  defp blob_allowed?(scopes, mime),
    do:
      Enum.any?(scopes, fn scope ->
        case blob(scope) do
          {:ok, permission} -> Enum.any?(permission.accept, &mime_covers?(&1, mime))
          _ -> false
        end
      end)

  defp mime_covers?(pattern, mime),
    do:
      pattern == "*/*" or pattern == mime or
        (String.ends_with?(pattern, "/*") and
           String.starts_with?(mime, String.trim_trailing(pattern, "*")))

  defp mime_pattern?("*/*"), do: true

  defp mime_pattern?(value) do
    # Media types are case-insensitive; only a complete subtype wildcard is supported.
    concrete =
      if String.ends_with?(value, "/*"), do: String.trim_trailing(value, "*") <> "x", else: value

    match?({:ok, _}, Atoll.Blobs.normalize_mime(concrete))
  end

  defp repo_allowed?(scopes, collection, action),
    do:
      Enum.any?(scopes, fn scope ->
        case repo(scope) do
          {:ok, permission} ->
            action in permission.actions and
              ("*" in permission.collections or collection in permission.collections)

          _ ->
            false
        end
      end)

  defp any_action?(scopes, action),
    do:
      Enum.any?(scopes, fn scope ->
        case repo(scope) do
          {:ok, permission} -> action in permission.actions
          _ -> false
        end
      end)

  defp syntax(value, resource, keys) when is_binary(value) and byte_size(value) in 1..4096 do
    with true <- Regex.match?(~r/\A[\x21\x23-\x5b\x5d-\x7e]+\z/, value),
         false <- Regex.match?(~r/%(?![0-9a-fA-F]{2})/, value),
         [base | rest] <- String.split(value, "?", parts: 2),
         {:ok, positional} <- positional(base, resource),
         {:ok, params} <- parameters(List.first(rest) || "", keys) do
      {:ok, positional, params}
    else
      _ -> {:error, :invalid_scope}
    end
  end

  defp syntax(_, _, _), do: {:error, :invalid_scope}

  defp positional(base, resource) do
    case String.split(base, ":", parts: 2) do
      [^resource] -> {:ok, nil}
      [^resource, value] -> {:ok, URI.decode(value)}
      _ -> {:error, :invalid_scope}
    end
  end

  defp parameters("", _), do: {:ok, %{}}

  defp parameters(query, keys) do
    pairs = String.split(query, "&")

    if length(pairs) <= 128 do
      Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
        case String.split(pair, "=", parts: 2) do
          [key, value] ->
            key = URI.decode_www_form(key)
            value = URI.decode_www_form(value)

            if key in keys and String.valid?(value) and value != "",
              do: {:cont, {:ok, Map.update(acc, key, [value], &(&1 ++ [value]))}},
              else: {:halt, {:error, :invalid_scope}}

          _ ->
            {:halt, {:error, :invalid_scope}}
        end
      end)
    else
      {:error, :invalid_scope}
    end
  end
end
