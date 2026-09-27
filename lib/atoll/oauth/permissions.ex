defmodule Atoll.OAuth.Permissions do
  @moduledoc "Bounded OAuth permission scopes with semantic coverage."
  @legacy ~w(atproto transition:generic transition:chat.bsky transition:email)
  @actions ~w(create update delete)

  def supported?(scope),
    do:
      scope in @legacy or match?({:ok, _}, repo(scope)) or match?({:ok, _}, blob(scope)) or
        match?({:ok, _}, rpc(scope)) or match?({:ok, _}, account(scope)) or
        match?({:ok, _}, identity(scope)) or match?({:ok, _}, include(scope))

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

  def rpc(value) do
    with {:ok, positional, params} <- syntax(value, "rpc", ~w(lxm aud)),
         true <- is_nil(positional) or not Map.has_key?(params, "lxm"),
         methods = if(positional, do: [positional], else: params["lxm"]),
         true <- is_list(methods) and methods != [],
         true <- Enum.all?(methods, &(&1 == "*" or Atoll.Syntax.nsid?(&1))),
         [audience] <- params["aud"],
         true <- audience == "*" or service_reference?(audience),
         false <- audience == "*" and "*" in methods do
      {:ok, %{methods: Enum.uniq(methods), audience: audience}}
    else
      _ -> {:error, :invalid_scope}
    end
  end

  def account(value) do
    with {:ok, positional, params} <- syntax(value, "account", ~w(attr action)),
         true <- is_nil(positional) or not Map.has_key?(params, "attr"),
         [attr] <- if(positional, do: [positional], else: params["attr"]),
         true <- attr in ["email", "repo"],
         [action] <- Map.get(params, "action", ["read"]),
         true <- action in ["read", "manage"] do
      {:ok, %{attr: attr, action: action}}
    else
      _ -> {:error, :invalid_scope}
    end
  end

  @doc "Parse a permission-set invocation with a scalar NSID and optional service audience."
  def include(value) do
    with {:ok, positional, params} <- syntax(value, "include", ~w(nsid aud)),
         true <- is_nil(positional) or not Map.has_key?(params, "nsid"),
         [nsid] <- if(positional, do: [positional], else: params["nsid"]),
         true <- Atoll.Syntax.nsid?(nsid),
         [audience] <- Map.get(params, "aud", [nil]),
         true <- is_nil(audience) or service_reference?(audience) do
      {:ok, %{nsid: nsid, audience: audience}}
    else
      _ -> {:error, :invalid_scope}
    end
  end

  def identity(value) do
    with {:ok, positional, params} <- syntax(value, "identity", ["attr"]),
         true <- is_nil(positional) or not Map.has_key?(params, "attr"),
         [attr] <- if(positional, do: [positional], else: params["attr"]),
         true <- attr in ["handle", "*"] do
      {:ok, %{attr: attr}}
    else
      _ -> {:error, :invalid_scope}
    end
  end

  def allows_identity?(scope, attr), do: identity_allowed?(String.split(scope, " "), attr)

  defp identity_allowed?(scopes, attr) do
    Enum.any?(scopes, fn scope ->
      case identity(scope) do
        {:ok, permission} -> permission.attr == "*" or permission.attr == attr
        _ -> false
      end
    end)
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
            {:ok, permission} ->
              Enum.all?(permission.accept, &blob_allowed?(granted, &1))

            _ ->
              case rpc(requested) do
                {:ok, permission} ->
                  Enum.all?(permission.methods, &rpc_allowed?(granted, permission.audience, &1))

                _ ->
                  case account(requested) do
                    {:ok, permission} ->
                      account_allowed?(granted, permission.attr, permission.action)

                    _ ->
                      case identity(requested) do
                        {:ok, permission} -> identity_allowed?(granted, permission.attr)
                        _ -> include_covered?(granted, requested)
                      end
                  end
              end
          end
      end
    end
  end

  defp include_covered?(granted, requested) do
    with {:ok, target} <- include(requested) do
      Enum.any?(granted, fn value ->
        case include(value) do
          {:ok, permission} ->
            permission.nsid == target.nsid and
              (permission.audience == target.audience or is_nil(target.audience))

          _ ->
            false
        end
      end)
    else
      _ -> false
    end
  end

  def write_admission?(scope, :refresh_identity), do: "atproto" in String.split(scope, " ")

  def write_admission?(scope, :update_handle), do: allows_identity?(scope, "handle")

  def write_admission?(scope, action)
      when action in [:request_plc_signature, :sign_plc_operation, :submit_plc_operation],
      do: allows_identity?(scope, "*")

  def write_admission?(scope, :import_repo), do: allows_account?(scope, "repo", "manage")

  def write_admission?(scope, action)
      when action in [
             :request_email_confirmation,
             :confirm_email,
             :request_email_update,
             :update_email
           ],
      do: allows_account?(scope, "email", "manage")

  def write_admission?(scope, :put_preferences),
    do: allows_preferences?(scope, "app.bsky.actor.putPreferences")

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

  def allows_rpc?(scope, audience, method),
    do: rpc_allowed?(String.split(scope, " "), audience, method)

  @doc "Locally served actor preferences follow the transitional or AppView RPC grants."
  def allows_preferences?(scope, method) do
    scopes = String.split(scope, " ")

    "transition:generic" in scopes or
      rpc_allowed?(scopes, Application.get_env(:atoll, :appview_proxy), method)
  end

  def allows_account?(scope, attr, action) do
    scopes = String.split(scope, " ")

    (attr == "email" and action == "read" and "transition:email" in scopes) or
      account_allowed?(scopes, attr, action)
  end

  defp account_allowed?(scopes, attr, action),
    do:
      Enum.any?(scopes, fn scope ->
        case account(scope) do
          {:ok, permission} ->
            permission.attr == attr and
              (permission.action == action or (permission.action == "manage" and action == "read"))

          _ ->
            false
        end
      end)

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
            case rpc(scope) do
              {:ok, permission} ->
                methods =
                  Enum.map_join(permission.methods, ", ", fn
                    "*" -> "all methods"
                    method -> method
                  end)

                audience =
                  if permission.audience == "*", do: "any service", else: permission.audience

                "Call application services: " <> methods <> " on " <> audience

              _ ->
                case account(scope) do
                  {:ok, %{attr: "email", action: "read"}} ->
                    "Read your email address and confirmation status"

                  {:ok, %{attr: "email", action: "manage"}} ->
                    "Read and change your email address and email authentication settings"

                  {:ok, %{attr: "repo", action: "manage"}} ->
                    "Replace your entire public repository by importing an archive"

                  {:ok, %{attr: "repo", action: "read"}} ->
                    "Read public repository information (no additional access)"

                  _ ->
                    case identity(scope) do
                      {:ok, %{attr: "handle"}} ->
                        "Change your handle"

                      {:ok, %{attr: "*"}} ->
                        "Control your DID and handle, including account migration and identity keys"

                      _ ->
                        nil
                    end
                end
            end
        end
    end
  end

  defp rpc_allowed?(scopes, audience, method),
    do:
      Enum.any?(scopes, fn scope ->
        case rpc(scope) do
          {:ok, permission} ->
            (permission.audience == "*" or permission.audience == audience) and
              ("*" in permission.methods or method in permission.methods)

          _ ->
            false
        end
      end)

  defp service_reference?(value) when is_binary(value) and byte_size(value) <= 2048 do
    case String.split(value, "#") do
      [did, fragment] ->
        Atoll.Syntax.did?(did) and not Regex.match?(~r/%(?![0-9a-fA-F]{2})/, did) and
          Regex.match?(~r/\A(?:[A-Za-z0-9._~!$&'()*+,;=:@\/?-]|%[0-9a-fA-F]{2})+\z/, fragment)

      _ ->
        false
    end
  end

  defp service_reference?(_), do: false

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
