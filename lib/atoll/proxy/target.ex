defmodule Atoll.Proxy.Target do
  @moduledoc """
  Resolves an explicit XRPC service audience to an HTTPS origin and pins its public IP.

  This is transport preparation, not authorization. Callers must admit an active
  account before resolution and recheck its grant before issuing a service JWT.
  Resolver and lookup options are trusted operator/test options only.
  """
  alias Atoll.{Identity.Resolver, Syntax}

  @enforce_keys [:audience, :uri, :address]
  defstruct [:audience, :uri, :address]

  @fragment ~r/\A(?:[A-Za-z0-9._~!$&'()*+,;=:@\/?-]|%[0-9a-fA-F]{2})+\z/

  def parse(value) when is_binary(value) and byte_size(value) <= 2048 do
    case String.split(value, "#") do
      [did, fragment] ->
        if Syntax.did?(did) and Regex.match?(@fragment, fragment),
          do: {:ok, {did, fragment}},
          else: {:error, :invalid_proxy_target}

      _ ->
        {:error, :invalid_proxy_target}
    end
  end

  def parse(_), do: {:error, :invalid_proxy_target}

  def resolve(audience, opts \\ []) do
    with {:ok, {did, _}} <- parse(audience),
         {:ok, document} <- Resolver.resolve_document(did, Keyword.get(opts, :resolver, [])),
         {:ok, uri} <- endpoint(document, audience),
         {:ok, address} <- Keyword.get(opts, :lookup, &Resolver.lookup/1).(uri.host),
         true <- Resolver.public_address?(address) do
      {:ok, %__MODULE__{audience: audience, uri: uri, address: address}}
    else
      false -> {:error, :unsafe_proxy_destination}
      {:error, _} = error -> error
    end
  end

  @doc "Validates a service entry from an already authenticated DID document."
  def endpoint(document, audience) do
    with {:ok, {did, fragment}} <- parse(audience),
         %{"id" => ^did, "service" => services} when is_list(services) <- document,
         true <- length(services) <= 64,
         [service] <- Enum.filter(services, &matches?(&1, did, fragment)),
         %{"type" => type, "serviceEndpoint" => url}
         when is_binary(type) and byte_size(type) in 1..256 <- service,
         {:ok, uri} <- origin(url) do
      {:ok, uri}
    else
      _ -> {:error, :invalid_proxy_service}
    end
  end

  defp matches?(%{"id" => id}, did, fragment), do: id in ["#" <> fragment, did <> "#" <> fragment]
  defp matches?(_, _, _), do: false

  # XRPC endpoints live at the origin's top-level /xrpc/ path. Reject URL
  # credentials, prefixes and ambiguous bytes instead of normalizing them.
  defp origin(url) when is_binary(url) and byte_size(url) <= 2048 do
    with false <- Regex.match?(~r/[\x00-\x20\x7f\\]/, url),
         {:ok,
          %URI{
            scheme: "https",
            host: host,
            port: port,
            userinfo: nil,
            query: nil,
            fragment: nil,
            path: path
          } = uri} <- URI.new(url),
         true <- is_binary(host) and host != "" and port in 1..65535,
         true <- path in [nil, "", "/"] do
      {:ok, uri}
    else
      _ -> {:error, :invalid_proxy_service}
    end
  end

  defp origin(_), do: {:error, :invalid_proxy_service}
end
