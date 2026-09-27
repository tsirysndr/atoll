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

    pds =
      Enum.reduce(
        [
          privacy_policy_url: url!(env, "ATOLL_PRIVACY_POLICY_URL"),
          terms_of_service_url: url!(env, "ATOLL_TERMS_OF_SERVICE_URL"),
          contact_email: email!(env, "ATOLL_CONTACT_EMAIL")
        ],
        pds,
        fn
          {_key, nil}, acc -> acc
          {key, value}, acc -> Keyword.put(acc, key, value)
        end
      )

    %{pds: pds, host: host && String.downcase(host)}
  end

  defp url!(env, name) do
    case env[name] do
      nil ->
        nil

      value ->
        with true <- is_binary(value) and byte_size(value) <= 2048,
             {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" <-
               URI.new(value) do
          value
        else
          _ -> raise "#{name} must be an HTTPS URL"
        end
    end
  end

  defp email!(env, name) do
    case env[name] do
      nil ->
        nil

      value ->
        case Atoll.Accounts.EmailAddress.normalize(value) do
          {:ok, email} -> email
          _ -> raise "#{name} must be a valid email address"
        end
    end
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
