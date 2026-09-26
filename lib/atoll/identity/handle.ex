defmodule Atoll.Identity.Handle do
  @moduledoc """
  DNS TXT and HTTPS handle resolution, plus bidirectional identity verification.

  DNS takes precedence. Conflicting valid DNS DIDs fail without HTTPS fallback.
  `resolve/2` returns a forward claim; `verify/2` additionally resolves the DID and
  checks its first claimed handle. DNS uses the system recursive resolver.
  HTTPS inherits public IPv4/IPv6 pinning, with at most three validated HTTPS redirects.
  Options are trusted test dependencies, never untrusted request parameters.
  """
  alias Atoll.Syntax
  alias Atoll.Identity.Resolver

  def resolve(handle, opts \\ []) do
    with {:ok, handle} <- normalize(handle) do
      txt = Keyword.get(opts, :txt_lookup, &txt_lookup/1)
      records = if byte_size(handle) <= 244, do: txt.("_atproto." <> handle), else: []

      case dns_did(records) do
        {:ok, did} -> {:ok, did}
        {:error, :ambiguous_handle} = error -> error
        :absent -> https_did(handle, opts)
      end
    end
  end

  def verify(handle, opts \\ []) do
    with {:ok, normalized} <- normalize(handle),
         {:ok, did} <- resolve(normalized, opts),
         {:ok, identity} <- Resolver.resolve(did, opts),
         true <- identity.claimed_handle == normalized do
      {:ok, Map.put(identity, :handle, normalized)}
    else
      false -> {:error, :handle_mismatch}
      error -> error
    end
  end

  defp normalize(handle) do
    if Syntax.handle?(handle) do
      normalized = String.downcase(handle)

      case Resolver.resolution_url("did:web:" <> normalized) do
        {:ok, _} -> {:ok, normalized}
        _ -> {:error, :invalid_handle}
      end
    else
      {:error, :invalid_handle}
    end
  end

  defp dns_did(records) do
    dids =
      records
      |> Enum.flat_map(fn parts ->
        case IO.iodata_to_binary(parts) do
          "did=" <> did -> if Syntax.did?(did), do: [did], else: []
          _ -> []
        end
      end)
      |> Enum.uniq()

    case dids do
      [] -> :absent
      [did] -> {:ok, did}
      _ -> {:error, :ambiguous_handle}
    end
  end

  defp https_did(handle, opts) do
    with {:ok, body} <- Resolver.fetch_handle(handle, opts),
         true <- String.valid?(body),
         did = String.trim(body),
         true <- Syntax.did?(did) do
      {:ok, did}
    else
      _ -> {:error, :handle_not_found}
    end
  end

  defp txt_lookup(name), do: :inet_res.lookup(String.to_charlist(name), :in, :txt, [], 3000)
end
