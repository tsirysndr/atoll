defmodule Atoll.Identity.Resolver do
  @moduledoc """
  HTTPS DID resolution through plc.directory or hostname-level did:web.

  Uses public IPv4/IPv6 destinations and pins the checked address. DID redirects are rejected;
  HTTPS handle lookups permit three validated redirect hops. Response bytes are bounded.
  PLC resolution supports directory HTTPS trust or independent audit-chain verification.
  Routine lookups use a bounded positive cache; force_refresh bypasses and replaces it.
  Options provide trusted transport/DNS injection for tests, never request input.
  """
  alias Atoll.{Syntax, Identity.Document}
  @max_bytes 262_144

  def resolve(did, opts \\ []) do
    with {:ok, doc} <- resolve_document(did, opts),
         {:ok, identity} <- Document.parse(doc, did) do
      {:ok, Map.put(identity, :document, doc)}
    end
  end

  @doc "Resolves a DID document without requiring a PDS service; useful for service identities."
  def resolve_document(did, opts \\ []) do
    with {:ok, url} <- resolution_url(did) do
      mode =
        Keyword.get(
          opts,
          :plc_resolution_mode,
          Application.get_env(:atoll, :plc_resolution_mode, :directory)
        )

      verified? = String.starts_with?(did, "did:plc:") and mode == :audit

      loader = fn ->
        cond do
          mode not in [:directory, :audit] -> {:error, :invalid_did_document}
          verified? -> load_audit_document(did, url, opts)
          true -> load_document(did, url, opts)
        end
      end

      cache_key = if verified?, do: {:plc_audit, did}, else: did

      # Reject invalid trusted policy values even if a directory cache entry exists.
      cache = if mode in [:directory, :audit], do: cache_server(opts), else: false

      case cache do
        false ->
          loader.()

        server ->
          Atoll.Identity.Cache.fetch(
            server,
            cache_key,
            Keyword.get(opts, :force_refresh, false),
            loader
          )
      end
    end
  end

  def plc_mode_from_env!(nil), do: :directory
  def plc_mode_from_env!("directory"), do: :directory
  def plc_mode_from_env!("audit"), do: :audit

  def plc_mode_from_env!(_),
    do: raise(ArgumentError, "ATOLL_PLC_RESOLUTION_MODE must be directory or audit")

  defp load_audit_document(did, url, opts) do
    with {:ok, body} <- fetch(url <> "/log/audit", opts, 8 * 1024 * 1024),
         {:ok, entries} <- Jason.decode(body),
         {:ok, document} <- Atoll.Identity.PLC.AuditLog.document(did, entries) do
      {:ok, document}
    else
      {:error, :invalid_plc_log} -> {:error, :invalid_did_document}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_did_document}
      {:error, _} = error -> error
    end
  end

  defp cache_server(opts) do
    # Custom transports/DNS are isolated unless a caller explicitly supplies a cache.
    default =
      if Keyword.has_key?(opts, :request) or Keyword.has_key?(opts, :lookup),
        do: false,
        else: Atoll.Identity.Cache

    Keyword.get(opts, :cache, default)
  end

  defp load_document(did, url, opts) do
    with {:ok, body} <- fetch(url, opts),
         {:ok, doc} <- Jason.decode(body),
         %{"id" => ^did} <- doc do
      {:ok, doc}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_did_document}
      {:error, _} = error -> error
      _ -> {:error, :invalid_did_document}
    end
  end

  def resolution_url("did:plc:" <> id) do
    if Regex.match?(~r/\A[a-z2-7]{24}\z/, id),
      do: {:ok, "https://plc.directory/did:plc:" <> id},
      else: {:error, :invalid_did}
  end

  def resolution_url("did:web:" <> host) do
    case Atoll.Identity.Localhost.url("did:web:" <> host) do
      {:ok, _} = local ->
        local

      _ ->
        if Syntax.handle?(host) and host == String.downcase(host) and
             List.last(String.split(host, ".")) not in ~w(alt arpa example internal invalid local localhost onion test) do
          {:ok, "https://" <> host <> "/.well-known/did.json"}
        else
          {:error, :invalid_did}
        end
    end
  end

  def resolution_url(did) do
    if Syntax.did?(did), do: {:error, :unsupported_did_method}, else: {:error, :invalid_did}
  end

  @doc false
  def fetch_handle(host, opts) do
    with true <- Syntax.handle?(host),
         {:ok, _} <- resolution_url("did:web:" <> host) do
      fetch("https://" <> host <> "/.well-known/atproto-did", opts, 4096, 3)
    else
      _ -> {:error, :invalid_handle}
    end
  end

  @doc "Fetch a public Lexicon record from an HTTPS PDS using the resolver's bounded, pinned transport."
  def fetch_lexicon(pds, did, nsid, opts \\ []) do
    fetch_lexicon_response(pds, did, nsid, opts, :json)
  end

  @doc "Fetch the signed CAR search-path proof for a public Lexicon record."
  def fetch_lexicon_proof(pds, did, nsid, opts \\ []) do
    fetch_lexicon_response(pds, did, nsid, opts, :proof)
  end

  @doc "Fetches an OAuth JSON document with a 64 KiB limit, no redirects, and exact HTTP 200 status."
  def fetch_oauth_document(url, opts \\ []) do
    with true <- is_binary(url) and byte_size(url) in 1..2048,
         {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}} <- URI.new(url),
         true <- is_binary(host) and host != "" do
      opts = opts |> Keyword.put(:accept, "application/json") |> Keyword.put(:oauth_json, true)
      fetch(url, opts, 65_536)
    else
      _ -> {:error, :invalid_oauth_document_url}
    end
  end

  defp fetch_lexicon_response(pds, did, nsid, opts, mode) do
    with true <- is_binary(pds) and Syntax.did?(did) and Syntax.nsid?(nsid),
         {:ok,
          %URI{
            scheme: "https",
            host: host,
            port: port,
            path: path,
            userinfo: nil,
            query: nil,
            fragment: nil
          } = uri} <- URI.new(pds),
         true <- is_binary(host) and host != "" and port in 1..65535 and path in [nil, "", "/"] do
      {method, params, limit, accept} =
        case mode do
          :json ->
            {"com.atproto.repo.getRecord", [repo: did], 262_144, "application/json"}

          :proof ->
            {"com.atproto.sync.getRecord", [did: did], 2_097_152, "application/vnd.ipld.car"}
        end

      query = URI.encode_query(params ++ [collection: "com.atproto.lexicon.schema", rkey: nsid])
      url = URI.to_string(%{uri | path: "/xrpc/" <> method, query: query})

      case fetch(url, Keyword.put(opts, :accept, accept), limit) do
        {:ok, body} -> {:ok, body}
        {:error, :did_document_too_large} -> {:error, :lexicon_too_large}
        {:error, :did_not_found} -> {:error, :lexicon_not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :invalid_lexicon_endpoint}
    end
  end

  defp fetch(url, opts, max_bytes \\ @max_bytes, redirects \\ 0) do
    uri = URI.parse(url)
    lookup = Keyword.get(opts, :lookup, &lookup/1)

    local? =
      uri.scheme == "http" and uri.host == "localhost" and Atoll.Identity.Localhost.enabled?()

    destination = if local?, do: {:ok, {127, 0, 0, 1}}, else: lookup.(uri.host)

    host = if String.contains?(uri.host, ":"), do: "[#{uri.host}]", else: uri.host

    authority =
      if uri.port != URI.default_port(uri.scheme),
        do: "#{host}:#{uri.port}",
        else: host

    with {:ok, address} <- destination,
         true <- public_address?(address) or (local? and address == {127, 0, 0, 1}) do
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
            {"host", authority},
            {"accept",
             Keyword.get(
               opts,
               :accept,
               if(max_bytes == 4096,
                 do: "text/plain",
                 else: "application/did+ld+json, application/json"
               )
             )},
            {"accept-encoding", "identity"}
          ],
          connect_options: [
            hostname: uri.host,
            timeout: 3000,
            transport_opts: [inet6: tuple_size(address) == 8, inet4: tuple_size(address) == 4]
          ],
          receive_timeout: 5000,
          request_timeout: 5000,
          into: fn event, pair -> collect(event, pair, max_bytes) end
        )

      case result do
        {:ok, %{body: :too_large}} ->
          {:error, :did_document_too_large}

        {:ok, %{status: status, body: body, headers: headers}}
        when status in 200..299 and is_binary(body) ->
          if Map.get(headers, "content-encoding", []) in [[], ["identity"]] and
               valid_response?(status, headers, opts),
             do: {:ok, body},
             else: {:error, :resolution_failed}

        {:ok, %{status: status, headers: headers}}
        when status in [301, 302, 303, 307, 308] and redirects > 0 ->
          with {:ok, target} <- redirect_target(url, headers) do
            fetch(target, opts, max_bytes, redirects - 1)
          end

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

  defp valid_response?(status, headers, opts) do
    if Keyword.get(opts, :oauth_json, false) do
      case Map.get(headers, "content-type", []) do
        [type] ->
          status == 200 and
            type |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() ==
              "application/json"

        _ ->
          false
      end
    else
      true
    end
  end

  defp redirect_target(base, headers) do
    with [location] when is_binary(location) and byte_size(location) in 1..2048 <-
           Map.get(headers, "location", []),
         true <- String.valid?(location) and not Regex.match?(~r/[\x00-\x20\x7f]/, location),
         {:ok, relative} <- URI.new(location),
         %URI{scheme: "https", host: host, port: 443, userinfo: nil, fragment: nil} = target <-
           URI.merge(base, relative),
         true <- is_binary(host),
         {:ok, _} <- resolution_url("did:web:" <> String.downcase(host)) do
      {:ok, URI.to_string(%{target | host: String.downcase(host)})}
    else
      _ -> {:error, :resolution_failed}
    end
  rescue
    ArgumentError -> {:error, :resolution_failed}
  end

  defp collect({:data, chunk}, {req, resp}, max_bytes) do
    if byte_size(resp.body) + byte_size(chunk) > max_bytes,
      do: {:halt, {req, %{resp | body: :too_large}}},
      else: {:cont, {req, %{resp | body: resp.body <> chunk}}}
  end

  @doc false
  def lookup(host, query \\ &:inet.getaddrs/3) do
    deadline = System.monotonic_time(:millisecond) + 3000

    Enum.reduce_while([:inet, :inet6], {:error, :dns_failed}, fn family, _ ->
      remaining = deadline - System.monotonic_time(:millisecond)

      result =
        if remaining > 0,
          do: query.(String.to_charlist(host), family, remaining),
          else: {:error, :timeout}

      address =
        case result do
          {:ok, addresses} when is_list(addresses) ->
            Enum.find(addresses, fn address ->
              if family == :inet, do: public_ipv4?(address), else: public_ipv6?(address)
            end)

          _ ->
            nil
        end

      if address, do: {:halt, {:ok, address}}, else: {:cont, {:error, :dns_failed}}
    end)
  end

  @doc false
  def public_address?(address), do: public_ipv4?(address) or public_ipv6?(address)

  @doc false
  def public_ipv6?({a, b, c, d, e, f, g, h})
      when a in 0x2000..0x3FFF and b in 0..0xFFFF and c in 0..0xFFFF and
             d in 0..0xFFFF and e in 0..0xFFFF and f in 0..0xFFFF and
             g in 0..0xFFFF and h in 0..0xFFFF do
    # Conservative subset of global unicast: exclude IETF assignments, documentation,
    # and 6to4. All mapped/translated, local and multicast ranges lie outside 2000::/3.
    not ((a == 0x2001 and b < 0x0200) or (a == 0x2001 and b == 0x0DB8) or
           a == 0x2002 or (a == 0x3FFF and b < 0x1000))
  end

  def public_ipv6?(_), do: false

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
