defmodule Atoll.OAuth.Permissions do
  @moduledoc "Bounded repository permission scopes and collection/action authorization."
  @legacy ~w(atproto transition:generic transition:chat.bsky transition:email)
  @actions ~w(create update delete)

  def supported?(scope), do: scope in @legacy or match?({:ok, _}, repo(scope))

  def repo(value) when is_binary(value) and byte_size(value) in 1..4096 do
    with true <- Regex.match?(~r/\A[\x21\x23-\x5b\x5d-\x7e]+\z/, value),
         false <- Regex.match?(~r/%(?![0-9a-fA-F]{2})/, value),
         [base | rest] <- String.split(value, "?", parts: 2),
         {:ok, positional} <- positional(base),
         {:ok, params} <- parameters(List.first(rest) || ""),
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

  def repo(_), do: {:error, :invalid_scope}

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
          false
      end
    end
  end

  def write_admission?(scope, action) do
    scopes = String.split(scope, " ")

    "transition:generic" in scopes or
      case action do
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

  def describe(scope) do
    {:ok, permission} = repo(scope)

    collections =
      Enum.map_join(permission.collections, ", ", fn
        "*" -> "all collections"
        collection -> collection
      end)

    "Write public records: " <> Enum.join(permission.actions, ", ") <> " in " <> collections
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

  defp positional("repo"), do: {:ok, nil}
  defp positional("repo:" <> value), do: {:ok, URI.decode(value)}
  defp positional(_), do: {:error, :invalid_scope}

  defp parameters(""), do: {:ok, %{}}

  defp parameters(query) do
    pairs = String.split(query, "&")

    if length(pairs) <= 128 do
      Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
        case String.split(pair, "=", parts: 2) do
          [key, value] ->
            key = URI.decode_www_form(key)
            value = URI.decode_www_form(value)

            if key in ["collection", "action"] and String.valid?(value) and value != "",
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
