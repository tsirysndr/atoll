defmodule Atoll.OAuth.PermissionSet do
  @moduledoc "Bounded permission-set documents and namespace-restricted expansion, without IO."
  alias Atoll.OAuth.Permissions
  alias Atoll.Lexicon.Language
  @max_bytes 262_144
  @max_permissions 256

  def validate(document, nsid) when is_map(document) do
    with %{
           "$type" => "com.atproto.lexicon.schema",
           "lexicon" => 1,
           "id" => ^nsid,
           "defs" =>
             %{"main" => %{"type" => "permission-set", "permissions" => permissions} = main} =
               defs
         } <- document,
         true <- Atoll.Syntax.nsid?(nsid),
         true <- is_list(permissions) and length(permissions) <= @max_permissions,
         true <-
           Enum.all?(defs, fn {name, definition} ->
             is_binary(name) and is_map(definition) and
               (name == "main" or
                  definition["type"] not in ~w(record query procedure subscription permission-set))
           end),
         true <-
           Map.keys(main) -- ~w(type description title title:lang detail detail:lang permissions) ==
             [],
         true <-
           optional_text?(main, "title", 256) and optional_text?(main, "detail", 4096) and
             optional_text?(main, "description", 4096),
         true <- localized?(main, "title:lang", 256) and localized?(main, "detail:lang", 4096),
         {:ok, bytes} <- Jason.encode(document),
         true <- byte_size(bytes) <= @max_bytes do
      {:ok, document}
    else
      _ -> {:error, :invalid_permission_set}
    end
  end

  def validate(_, _), do: {:error, :invalid_permission_set}

  def expand(document, %{nsid: nsid, audience: audience}) do
    with {:ok, _} <- validate(document, nsid) do
      scopes =
        document["defs"]["main"]["permissions"]
        |> Enum.flat_map(&permission(&1, nsid, audience))
        |> Enum.uniq()

      {:ok, scopes}
    end
  end

  # Unknown resources/fields and partially understood declarations grant nothing.
  # Reject the entire declaration if even one resource escapes its namespace.
  defp permission(
         %{"type" => "permission", "resource" => "repo", "collection" => collections} =
           declaration,
         nsid,
         _
       ) do
    actions = Map.get(declaration, "action", ~w(create update delete))

    if keys?(declaration, ~w(type resource collection action)) and resources?(collections, nsid) and
         is_list(actions) and actions != [] and length(actions) <= 3 and
         Enum.all?(actions, &(&1 in ~w(create update delete))) and Enum.uniq(actions) == actions do
      Enum.map(collections, fn collection ->
        encode("repo", [{"collection", collection} | Enum.map(actions, &{"action", &1})])
      end)
    else
      []
    end
  end

  defp permission(
         %{"type" => "permission", "resource" => "rpc", "lxm" => methods} = declaration,
         nsid,
         inherited
       ) do
    audience =
      cond do
        declaration["inheritAud"] == true and not Map.has_key?(declaration, "aud") -> inherited
        Map.get(declaration, "inheritAud", false) == false and declaration["aud"] == "*" -> "*"
        true -> nil
      end

    if keys?(declaration, ~w(type resource lxm aud inheritAud)) and
         resources?(methods, nsid, false) and
         is_binary(audience) do
      scopes = Enum.map(Enum.uniq(methods), &encode("rpc", [{"lxm", &1}, {"aud", audience}]))
      if Enum.all?(scopes, &match?({:ok, _}, Permissions.rpc(&1))), do: scopes, else: []
    else
      []
    end
  end

  defp permission(_, _, _), do: []

  defp resources?(values, nsid, unique? \\ true)

  defp resources?(values, nsid, unique?) when is_list(values) and length(values) in 1..128 do
    prefix = nsid |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")

    (not unique? or Enum.uniq(values) == values) and
      Enum.all?(values, &(Atoll.Syntax.nsid?(&1) and String.starts_with?(&1, prefix <> ".")))
  end

  defp resources?(_, _, _), do: false

  defp keys?(declaration, fields),
    do:
      Map.keys(declaration) -- ["description" | fields] == [] and
        optional_text?(declaration, "description", 4096)

  defp encode(resource, pairs), do: resource <> "?" <> URI.encode_query(pairs)

  defp optional_text?(map, key, max), do: not Map.has_key?(map, key) or text?(map[key], max)

  defp text?(value, max),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= max

  defp localized?(map, field, max) do
    case Map.fetch(map, field) do
      :error ->
        true

      {:ok, translations} when is_map(translations) and map_size(translations) <= 32 ->
        Enum.all?(translations, fn {locale, value} ->
          Language.valid?(locale) and text?(value, max)
        end)

      _ ->
        false
    end
  end
end
