defmodule Atoll.Identity.Resolver do
  @moduledoc """
  HTTPS DID resolution through plc.directory or hostname-level did:web.

  Uses public IPv4 destinations only, pins the checked address, rejects redirects,
  and limits response bytes. PLC resolution trusts the directory's HTTPS response;
  operation-log validation, caching, IPv6, and development localhost are pending.
  Options provide trusted transport/DNS injection for tests, never request input.
  """
  alias Atoll.{Syntax, Identity.Document}
  @max_bytes 262_144

  def resolve(did, opts \\ []) do
    with {:ok, url} <- resolution_url(did),
         {:ok, body} <- fetch(url, opts),
         {:ok, doc} <- Jason.decode(body),
         {:ok, identity} <- Document.parse(doc, did) do
      {:ok, Map.put(identity, :document, doc)}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_did_document}
      error -> error
    end
  end

  def resolution_url("did:plc:" <> id) do
    if Regex.match?(~r/\A[a-z2-7]{24}\z/, id),
      do: {:ok, "https://plc.directory/did:plc:" <> id},
      else: {:error, :invalid_did}
  end

  def resolution_url("did:web:" <> host) do
    if Syntax.handle?(host) and host == String.downcase(host) and
         List.last(String.split(host, ".")) not in ~w(alt arpa example internal invalid local localhost onion test) do
      {:ok, "https://" <> host <> "/.well-known/did.json"}
    else
      {:error, :invalid_did}
    end
  end

  def resolution_url(did) do
    if Syntax.did?(did), do: {:error, :unsupported_did_method}, else: {:error, :invalid_did}
  end

  defp fetch(url, opts) do
    uri = URI.parse(url)
    lookup = Keyword.get(opts, :lookup, &lookup/1)

    with {:ok, address} <- lookup.(uri.host),
         true <- public_ipv4?(address) do
      pinned = %{uri | host: address |> :inet.ntoa() |> to_string()} |> URI.to_string()
      request = Keyword.get_lazy(opts, :request, &Req.new/0)

      result =
        Req.get(request,
          url: pinned,
          redirect: false,
          retry: false,
          raw: true,
          compressed: false,
          headers: [
            {"host", uri.host},
            {"accept", "application/did+ld+json, application/json"},
            {"accept-encoding", "identity"}
          ],
          connect_options: [hostname: uri.host, timeout: 3000],
          receive_timeout: 5000,
          request_timeout: 5000,
          into: &collect/2
        )

      case result do
        {:ok, %{body: :too_large}} ->
          {:error, :did_document_too_large}

        {:ok, %{status: 200, body: body, headers: headers}} when is_binary(body) ->
          if Map.get(headers, "content-encoding", []) in [[], ["identity"]],
            do: {:ok, body},
            else: {:error, :resolution_failed}

        {:ok, %{status: 404}} ->
          {:error, :did_not_found}

        _ ->
          {:error, :resolution_failed}
      end
    else
      false -> {:error, :unsafe_destination}
      _ -> {:error, :resolution_failed}
    end
  end

  defp collect({:data, chunk}, {req, resp}) do
    if byte_size(resp.body) + byte_size(chunk) > @max_bytes,
      do: {:halt, {req, %{resp | body: :too_large}}},
      else: {:cont, {req, %{resp | body: resp.body <> chunk}}}
  end

  defp lookup(host) do
    case :inet.getaddrs(String.to_charlist(host), :inet, 3000) do
      {:ok, [address | _]} -> {:ok, address}
      _ -> {:error, :dns_failed}
    end
  end

  @doc false
  def public_ipv4?({a, b, c, d})
      when a in 1..223 and b in 0..255 and c in 0..255 and d in 0..255 do
    not (a in [10, 127] or (a == 100 and b in 64..127) or
           (a == 169 and b == 254) or (a == 172 and b in 16..31) or
           (a == 192 and b in [0, 168]) or (a == 198 and b in [18, 19, 51]) or
           (a == 203 and b == 0 and c == 113))
  end

  def public_ipv4?(_), do: false
end
