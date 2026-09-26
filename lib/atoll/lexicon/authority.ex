defmodule Atoll.Lexicon.Authority do
  @moduledoc "Exact DNS namespace delegation and fresh DID/PDS lookup for network Lexicon resolution."
  alias Atoll.Syntax
  alias Atoll.Identity.Resolver

  @doc "Resolve the delegated repository identity, without fetching or trusting a schema yet."
  def resolve(nsid, opts \\ []) do
    with {:ok, target} <- discover(nsid, opts),
         {:ok, identity} <- Resolver.resolve(target.did, Keyword.put(opts, :force_refresh, true)) do
      {:ok, Map.put(target, :identity, identity)}
    end
  end

  def discover(nsid, opts \\ []) do
    with {:ok, name} <- name(nsid),
         lookup = Keyword.get(opts, :txt_lookup, &txt_lookup/1),
         {:ok, did} <- claim(lookup.(name.dns)) do
      {:ok,
       Map.merge(name, %{
         did: did,
         uri: "at://" <> did <> "/com.atproto.lexicon.schema/" <> name.nsid
       })}
    end
  rescue
    _ in [ArgumentError, FunctionClauseError] -> {:error, :lexicon_authority_unavailable}
  catch
    :exit, _ -> {:error, :lexicon_authority_unavailable}
  end

  @doc "Normalize only the authority portion; never lowercase the case-sensitive NSID name."
  def name(nsid) do
    if Syntax.nsid?(nsid) do
      {parts, [record]} = nsid |> String.split(".") |> Enum.split(-1)
      parts = Enum.map(parts, &String.downcase/1)
      authority = parts |> Enum.reverse() |> Enum.join(".")
      dns = "_lexicon." <> authority

      with true <- byte_size(dns) <= 253,
           {:ok, _} <- Resolver.resolution_url("did:web:" <> authority) do
        {:ok, %{nsid: Enum.join(parts ++ [record], "."), authority: authority, dns: dns}}
      else
        _ -> {:error, :invalid_lexicon_authority}
      end
    else
      {:error, :invalid_nsid}
    end
  end

  defp claim(records) when is_list(records) and length(records) <= 32 do
    with {:ok, values} <- values(records, [], 0) do
      dids =
        values
        |> Enum.flat_map(fn
          "did=" <> did -> if Syntax.did?(did), do: [did], else: []
          _ -> []
        end)
        |> Enum.uniq()

      case dids do
        [did] -> {:ok, did}
        [] -> {:error, :lexicon_authority_not_found}
        _ -> {:error, :ambiguous_lexicon_authority}
      end
    end
  end

  defp claim(_), do: {:error, :lexicon_authority_unavailable}

  defp values([], acc, _), do: {:ok, acc}

  defp values([parts | rest], acc, size) when is_list(parts) and length(parts) <= 16 do
    if Enum.all?(parts, &chunk?/1) do
      value = IO.iodata_to_binary(parts)

      if byte_size(value) <= 2052 and size + byte_size(value) <= 16_384,
        do: values(rest, [value | acc], size + byte_size(value)),
        else: {:error, :lexicon_authority_unavailable}
    else
      {:error, :lexicon_authority_unavailable}
    end
  end

  defp values(_, _, _), do: {:error, :lexicon_authority_unavailable}
  defp chunk?(part) when is_binary(part), do: byte_size(part) <= 255

  defp chunk?(part) when is_list(part) and length(part) <= 255,
    do: Enum.all?(part, &(is_integer(&1) and &1 in 0..255))

  defp chunk?(_), do: false
  defp txt_lookup(name), do: :inet_res.lookup(String.to_charlist(name), :in, :txt, [], 3000)
end
