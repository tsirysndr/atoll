defmodule Atoll.Identity.Delegates do
  @moduledoc """
  Sibling PDS hosts that share this server's handle namespace.

  One handle domain can be served by several PDS instances — `*.bsky.social`
  works this way — because whichever server owns the wildcard answers handle
  resolution for the whole namespace, while the repositories themselves live
  wherever they live. This server owns `*.<user domain>`, so it answers for a
  delegate's accounts as well as its own, and the on-demand TLS ask endpoint
  follows the same answer so those names can get a certificate.

  A delegate is trusted only to name a DID for a handle inside this namespace.
  """

  @did ~r/\A(did:plc:[a-z2-7]{24}|did:web:[a-z0-9.:%-]{1,250})\z/

  @doc "Parses `ATOLL_HANDLE_DELEGATES`, a comma-separated list of PDS origins."
  def parse!(env, settings \\ []) do
    case Map.fetch(env, "ATOLL_HANDLE_DELEGATES") do
      {:ok, value} -> validate!(String.split(value, ","))
      :error -> settings
    end
  end

  defp validate!(values) do
    origins = values |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    Enum.each(origins, fn origin ->
      uri = URI.parse(origin)

      unless uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
               uri.path in [nil, "/"] and is_nil(uri.query) and is_nil(uri.fragment) and
               is_nil(uri.userinfo) do
        raise "ATOLL_HANDLE_DELEGATES must be a comma-separated list of PDS origins, got #{inspect(origin)}"
      end
    end)

    Enum.map(origins, &String.trim_trailing(&1, "/"))
  end

  @doc """
  The DID a delegate claims for `handle`, or `:error` when none does.

  An answer is cached for the delegate cache's lifetime. Every resolution in
  this namespace otherwise costs a round trip to another server, on paths that
  run per request — the handle's well-known document and the TLS ask among them
  — and a delegate that is briefly slow then looks like a handle that does not
  exist. Only answers are cached; a failure is retried.
  """
  def resolve(handle, opts \\ []) do
    if handle?(handle) do
      loader = fn -> ask_delegates(handle, opts) end

      case Keyword.get(opts, :cache, Atoll.Identity.DelegateCache) do
        false -> loader.()
        server -> Atoll.Identity.Cache.fetch(server, {:handle, handle}, false, loader)
      end
    else
      :error
    end
  end

  defp ask_delegates(handle, opts) do
    Enum.reduce_while(configured(), :error, fn origin, _ ->
      case ask(origin, handle, opts) do
        {:ok, did} -> {:halt, {:ok, did}}
        :error -> {:cont, :error}
      end
    end)
  end

  @doc """
  `:ok` unless a delegate already claims `handle` for a different DID.

  A hosted handle is otherwise free to allocate because this server owns the
  domain, which stops being true once a delegate issues names in it. Only an
  answered claim counts as taken: a delegate that cannot be reached leaves the
  name unproven, so an outage there does not stop registration here.
  """
  def available(handle, did \\ nil, opts \\ []) do
    # Allocation asks live. A cached answer only ever says a name is taken, and
    # serving that from cache refuses a name that has since been given up, or
    # one this caller is entitled to; the read paths carry the cache instead.
    case resolve(handle, Keyword.put_new(opts, :cache, false)) do
      {:ok, ^did} -> :ok
      {:ok, _} -> {:error, :handle_not_available}
      :error -> :ok
    end
  end

  def configured, do: Application.get_env(:atoll, :handle_delegates, [])

  defp handle?(handle) do
    is_binary(handle) and byte_size(handle) in 1..253 and
      Regex.match?(~r/\A[a-z0-9.-]+\z/, handle)
  end

  # This runs on the TLS handshake path through the ask endpoint, so it fails
  # fast rather than holding a connection open.
  defp ask(origin, handle, opts) do
    request = [
      url: "#{origin}/xrpc/com.atproto.identity.resolveHandle",
      params: [handle: handle],
      redirect: false,
      retry: false,
      connect_options: [timeout: 2_000],
      receive_timeout: 3_000
    ]

    # Only the transport can be overridden, so a caller cannot redirect the
    # question somewhere else.
    transport =
      case Keyword.fetch(opts, :plug) do
        {:ok, plug} -> [plug: plug]
        :error -> Application.get_env(:atoll, :handle_delegate_transport, [])
      end

    case Req.get(Keyword.merge(request, transport)) do
      {:ok, %{status: 200, body: %{"did" => did}}} when is_binary(did) ->
        if Regex.match?(@did, did), do: {:ok, did}, else: :error

      _ ->
        :error
    end
  end
end
