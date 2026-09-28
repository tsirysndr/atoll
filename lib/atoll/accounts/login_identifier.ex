defmodule Atoll.Accounts.LoginIdentifier do
  @moduledoc "Resolves a login identifier (handle, DID or email address) to a session."

  alias Atoll.Accounts.Sessions

  @doc "Creates a session, returning the resolved handle when one was used."
  def create_session(identifier, password, opts \\ []) do
    if String.contains?(identifier, "@") do
      with {:ok, pair} <- Sessions.create_email(identifier, password, opts), do: {:ok, pair, nil}
    else
      with {:ok, did, handle} <- resolve(identifier),
           {:ok, pair} <- Sessions.create(did, password, opts),
           do: {:ok, pair, handle}
    end
  end

  @doc "Resolves a DID or handle to `{:ok, did, handle}`."
  def resolve(identifier) do
    if Atoll.Syntax.did?(identifier) do
      {:ok, identifier, nil}
    else
      opts =
        Application.get_env(:atoll, :identity_resolution_options, [])
        |> Keyword.put(:force_refresh, true)

      case Atoll.Identity.Handle.verify(identifier, opts) do
        {:ok, identity} -> {:ok, identity.did, identity.handle}
        {:error, _} -> {:error, :invalid_credentials}
      end
    end
  end

  @doc "Whether the identifier could name an account at all."
  def valid?(identifier) when is_binary(identifier) do
    Atoll.Syntax.did?(identifier) or Atoll.Syntax.handle?(identifier) or
      match?({:ok, _}, Atoll.Accounts.EmailAddress.normalize(identifier))
  end

  def valid?(_), do: false
end
