defmodule Atoll.ServerConfig do
  @moduledoc "Validates runtime server metadata without resolving or provisioning identities."

  def parse!(env, production?) do
    did = env["ATOLL_PDS_DID"]
    host = env["PHX_HOST"]

    if production? and is_nil(did), do: raise("ATOLL_PDS_DID is required in production")
    if production? and is_nil(host), do: raise("PHX_HOST is required in production")

    if did && not Atoll.Syntax.did?(did), do: raise("ATOLL_PDS_DID must be a valid DID")

    if host && not Atoll.Syntax.handle?(host),
      do: raise("PHX_HOST must be a DNS hostname without a scheme, port, or path")

    domains =
      case env["ATOLL_AVAILABLE_USER_DOMAINS"] do
        nil -> if production?, do: [], else: nil
        "" -> []
        value -> parse_domains!(value)
      end

    pds = []
    pds = if did, do: Keyword.put(pds, :did, did), else: pds
    pds = if domains, do: Keyword.put(pds, :available_user_domains, domains), else: pds
    %{pds: pds, host: host && String.downcase(host)}
  end

  defp parse_domains!(value) do
    value
    |> String.split(",")
    |> Enum.map(fn entry ->
      case entry |> String.trim() |> String.downcase() do
        "." <> domain = suffix ->
          if Atoll.Syntax.handle?(domain),
            do: suffix,
            else: raise("ATOLL_AVAILABLE_USER_DOMAINS must contain dot-prefixed DNS suffixes")

        _ ->
          raise "ATOLL_AVAILABLE_USER_DOMAINS must contain dot-prefixed DNS suffixes"
      end
    end)
    |> Enum.uniq()
  end
end
