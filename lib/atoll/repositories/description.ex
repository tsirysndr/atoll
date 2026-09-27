defmodule Atoll.Repositories.Description do
  @moduledoc "Describes a locally hosted repository using its resolved identity and current collections."
  alias Atoll.{Repositories, Syntax}
  alias Atoll.Identity.{Handle, Resolver}

  def get(identifier, opts \\ []) do
    with {:ok, description} <- metadata(identifier, opts),
         {:ok, collections} <-
           Repositories.collections(description.did,
             max_bytes: Keyword.get(opts, :max_collection_bytes, 64 * 1024 * 1024)
           ),
         do: {:ok, Map.put(description, :collections, collections)}
  end

  @doc "Resolves identity before opening a bounded collection cursor, then calls consume.(metadata, names)."
  def stream(identifier, consume, opts \\ []) when is_function(consume, 2) do
    with {:ok, description} <- metadata(identifier, opts),
         do: Repositories.stream_collections(description.did, &consume.(description, &1))
  end

  defp metadata(identifier, opts) do
    with {:ok, did} <- did(identifier, opts),
         {:ok, _} <- Repositories.get_active_head(did),
         {:ok, identity} <- identity(did, opts) do
      claimed = identity.claimed_handle
      correct = is_binary(claimed) and Handle.resolve(claimed, opts) == {:ok, did}

      if not Syntax.did?(identifier) and
           (not correct or String.downcase(identifier) != claimed) do
        {:error, :unverified_handle}
      else
        {:ok,
         %{
           did: did,
           didDoc: identity.document,
           handle: if(correct, do: claimed, else: "handle.invalid"),
           handleIsCorrect: correct
         }}
      end
    end
  end

  defp did(identifier, opts) do
    cond do
      Syntax.did?(identifier) ->
        {:ok, identifier}

      Syntax.handle?(identifier) ->
        case Handle.resolve(identifier, opts) do
          {:ok, did} -> {:ok, did}
          {:error, :invalid_handle} -> {:error, :invalid_request}
          _ -> {:error, :unverified_handle}
        end

      true ->
        {:error, :invalid_request}
    end
  end

  defp identity(did, opts) do
    case Resolver.resolve(did, opts) do
      {:ok, identity} -> {:ok, identity}
      _ -> {:error, :identity_unavailable}
    end
  end
end
