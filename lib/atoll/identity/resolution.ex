defmodule Atoll.Identity.Resolution do
  @moduledoc "Read-only identity queries using bounded DID resolution and verified handle claims."
  alias Atoll.Identity.{Handle, Resolver}

  def did(did, opts \\ []) do
    with {:ok, document} <- Resolver.resolve_document(did, opts), do: {:ok, %{didDoc: document}}
  end

  def identity(identifier, opts \\ []) do
    with {:ok, did} <- identify(identifier, opts),
         {:ok, identity} <- Resolver.resolve(did, opts) do
      handle =
        if is_binary(identity.claimed_handle) and
             Handle.resolve(identity.claimed_handle, opts) == {:ok, did},
           do: identity.claimed_handle,
           else: "handle.invalid"

      {:ok, %{did: did, handle: handle, didDoc: identity.document}}
    end
  end

  defp identify(identifier, opts) do
    cond do
      Atoll.Syntax.did?(identifier) -> {:ok, identifier}
      Atoll.Syntax.handle?(identifier) -> Handle.resolve(identifier, opts)
      true -> {:error, :invalid_request}
    end
  end
end
