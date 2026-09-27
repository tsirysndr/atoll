defmodule Atoll.OAuth.PermissionSnapshots do
  @moduledoc "Fixed, grant-bound permission-set documents for consent, codes and access tokens."
  alias Atoll.OAuth.{Permissions, PermissionSet, PermissionSets}
  alias Atoll.Lexicon.Authority
  @max_sets 16
  @max_bytes 1_048_576
  @max_effective_bytes 262_144

  def resolve(scope, fallback \\ %{}, opts \\ []) do
    resolution =
      Keyword.get(
        opts,
        :permission_set_options,
        Application.get_env(:atoll, :lexicon_resolution_options, [])
      )

    deadline = System.monotonic_time(:millisecond) + 30_000

    with {:ok, includes} <- includes(scope),
         {:ok, snapshots} <-
           Enum.reduce_while(includes, {:ok, %{}}, fn include, {:ok, acc} ->
             if Map.has_key?(acc, include.nsid) do
               {:cont, {:ok, acc}}
             else
               options =
                 Keyword.put(resolution, :existing_session, Map.has_key?(fallback, include.nsid))

               result =
                 case PermissionSets.resolve(include.scope, options) do
                   {:ok, resolved} ->
                     {:ok,
                      Map.new(Map.take(resolved, [:document, :provenance, :fetched_at]), fn {k, v} ->
                        {Atom.to_string(k), v}
                      end)}

                   error ->
                     if valid_entry?(fallback[include.nsid], include.nsid),
                       do: {:ok, fallback[include.nsid]},
                       else: error
                 end

               case result do
                 {:ok, entry} ->
                   if System.monotonic_time(:millisecond) < deadline,
                     do: {:cont, {:ok, Map.put(acc, include.nsid, entry)}},
                     else: {:halt, {:error, :permission_set_unavailable}}

                 error ->
                   {:halt, error}
               end
             end
           end),
         {:ok, selected} <- select(scope, snapshots) do
      {:ok, selected}
    end
  end

  def select(scope, snapshots) when is_map(snapshots) do
    with {:ok, includes} <- includes(scope),
         true <- Enum.all?(includes, &valid_entry?(snapshots[&1.nsid], &1.nsid)),
         selected = Map.take(snapshots, Enum.map(includes, & &1.nsid)),
         {:ok, bytes} <- Jason.encode(selected),
         true <- byte_size(bytes) <= @max_bytes,
         {:ok, _} <- effective(scope, selected) do
      {:ok, selected}
    else
      _ -> {:error, :invalid_scope}
    end
  end

  def select(_, _), do: {:error, :invalid_scope}

  def effective(scope, snapshots) when is_binary(scope) and is_map(snapshots) do
    with {:ok, includes} <- includes(scope),
         {:ok, expanded} <-
           Enum.reduce_while(includes, {:ok, []}, fn include, {:ok, acc} ->
             case snapshots[include.nsid] do
               %{"document" => document} ->
                 case PermissionSet.expand(document, include) do
                   {:ok, permissions} -> {:cont, {:ok, permissions ++ acc}}
                   _ -> {:halt, {:error, :invalid_scope}}
                 end

               _ ->
                 {:halt, {:error, :invalid_scope}}
             end
           end) do
      direct = String.split(scope, " ") -- Enum.map(includes, & &1.scope)
      effective = Enum.join(Enum.uniq(direct ++ expanded), " ")

      if byte_size(effective) <= @max_effective_bytes,
        do: {:ok, effective},
        else: {:error, :invalid_scope}
    end
  end

  def effective(_, _), do: {:error, :invalid_scope}

  def entry(scope, snapshots) do
    with {:ok, [include]} <- includes(scope),
         entry when is_map(entry) <- snapshots[include.nsid],
         true <- valid_entry?(entry, include.nsid),
         {:ok, scopes} <- PermissionSet.expand(entry["document"], include) do
      {:ok, Map.put(entry["document"]["defs"]["main"], "scopes", scopes)}
    else
      _ -> {:error, :invalid_scope}
    end
  end

  defp includes(scope) when is_binary(scope) and byte_size(scope) <= 4096 do
    String.split(scope, " ")
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      if String.starts_with?(value, "include:") or String.starts_with?(value, "include?") or
           value == "include" do
        with {:ok, include} <- Permissions.include(value),
             {:ok, target} <- Authority.name(include.nsid),
             true <- length(acc) < @max_sets do
          {:cont, {:ok, [Map.merge(include, %{nsid: target.nsid, scope: value}) | acc]}}
        else
          _ -> {:halt, {:error, :invalid_scope}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp includes(_), do: {:error, :invalid_scope}

  defp valid_entry?(
         %{"document" => doc, "provenance" => provenance, "fetched_at" => timestamp},
         nsid
       ),
       do:
         is_map(provenance) and is_integer(timestamp) and timestamp > 0 and
           match?({:ok, _}, PermissionSet.validate(doc, nsid))

  defp valid_entry?(_, _), do: false
end
