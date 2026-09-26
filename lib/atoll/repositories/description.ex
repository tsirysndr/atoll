defmodule Atoll.Repositories.Description do
  @moduledoc "Describes a locally hosted repository using its resolved identity and current collections."
  alias Atoll.{Repositories, Syntax}
  alias Atoll.Identity.{Handle, Resolver}

  def get(identifier, opts \\ []) do
    with {:ok, did} <- did(identifier, opts),
         {:ok, collections} <- Repositories.collections(did),
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
           collections: collections,
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
