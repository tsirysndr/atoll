defmodule Atoll.Lexicon.Catalog do
  @moduledoc """
  Resolves a bounded, request-local catalog of supported record Lexicons.
  Each remote namespace is independently authenticated by Fetcher. Bundled schemas
  remain authoritative. No global application configuration or cache is mutated.
  """
  alias Atoll.Lexicon.{Authority, Fetcher, Loader, Schema}

  @max_documents 16
  @max_bytes 1_048_576
  @duration_ms 30_000

  def resolve(nsid, opts \\ []) do
    resolve_many([nsid], opts)
  end

  def resolve_many(nsids, opts \\ []) when is_list(nsids) and length(nsids) <= 200 do
    with {:ok, names} <- names(nsids) do
      clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

      state = %{
        documents: %{},
        provenance: %{},
        bytes: 0,
        builtins: Schema.builtin_documents(),
        clock: clock,
        deadline: clock.() + @duration_ms
      }

      walk(names, state, opts)
    end
  end

  defp names(nsids) do
    Enum.reduce_while(nsids, {:ok, []}, fn nsid, {:ok, acc} ->
      case Authority.name(nsid) do
        {:ok, target} -> {:cont, {:ok, [target.nsid | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, names |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp walk(queue, state, opts) do
    if state.clock.() >= state.deadline,
      do: {:error, :lexicon_resolution_timeout},
      else: continue(queue, state, opts)
  end

  defp continue([], state, _) do
    try do
      custom = Loader.validate!(Map.values(state.documents))
      {:ok, %{documents: Map.merge(custom, state.builtins), provenance: state.provenance}}
    rescue
      ArgumentError -> {:error, :invalid_lexicon_schema}
    end
  end

  defp continue([nsid | rest], state, opts) do
    cond do
      Map.has_key?(state.documents, nsid) or Map.has_key?(state.builtins, nsid) ->
        walk(rest, state, opts)

      map_size(state.documents) >= @max_documents ->
        {:error, :lexicon_catalog_too_large}

      true ->
        fetch = Keyword.get(opts, :fetch, &Fetcher.fetch/2)

        with {:ok, %{nsid: ^nsid, document: record} = result} <- fetch.(nsid, opts),
             %{"$type" => "com.atproto.lexicon.schema", "id" => ^nsid} <- record,
             document = Map.delete(record, "$type"),
             {:ok, dependencies} <- Loader.dependencies(document) do
          bytes = state.bytes + byte_size(Jason.encode!(record))
          documents = Map.put(state.documents, nsid, document)
          queue = Enum.uniq(rest ++ dependencies)

          pending =
            Enum.reject(queue, &(Map.has_key?(documents, &1) or Map.has_key?(state.builtins, &1)))

          if bytes <= @max_bytes and map_size(documents) + length(pending) <= @max_documents do
            provenance =
              Map.put(state.provenance, nsid, Map.take(result, [:did, :uri, :cid, :commit, :rev]))

            walk(
              queue,
              %{state | documents: documents, provenance: provenance, bytes: bytes},
              opts
            )
          else
            {:error, :lexicon_catalog_too_large}
          end
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_lexicon_schema}
        end
    end
  end
end
