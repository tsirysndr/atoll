defmodule Atoll.Relays do
  @moduledoc "Operator-requested crawl announcements to explicitly configured relay origins."

  def from_env!(nil), do: []
  def from_env!(""), do: []

  def from_env!(value) when is_binary(value) and byte_size(value) <= 4096 do
    urls = String.split(value, ",") |> Enum.map(&String.trim/1)

    case validate(urls) do
      {:ok, origins} -> origins
      _ -> invalid!()
    end
  end

  def from_env!(_), do: invalid!()

  def request_crawl(opts \\ []) do
    urls = Application.get_env(:atoll, :relay_urls, [])
    hostname = Keyword.get_lazy(opts, :hostname, fn -> hostname(AtollWeb.Endpoint.url()) end)

    with {:ok, origins} <- validate(urls),
         true <- origins != [],
         true <- valid_host?(hostname) do
      {:ok, Enum.map(origins, &request(&1, String.downcase(hostname), opts))}
    else
      false -> {:error, :relay_configuration_invalid}
      _ -> {:error, :relay_configuration_invalid}
    end
  end

  defp request(origin, host, opts) do
    options = [
      url: origin <> "/xrpc/com.atproto.sync.requestCrawl",
      json: %{hostname: host},
      redirect: false,
      retry: false,
      raw: true,
      compressed: false,
      headers: [{"accept", "application/json"}, {"accept-encoding", "identity"}],
      connect_options: [timeout: 3000],
      receive_timeout: 5000,
      request_timeout: 5000,
      into: fn {:data, bytes}, {request, response} ->
        if byte_size(response.body) + byte_size(bytes) > 4096,
          do: {:halt, {request, %{response | body: :too_large}}},
          else: {:cont, {request, %{response | body: response.body <> bytes}}}
      end
    ]

    outcome =
      case Req.post(Keyword.merge(options, Keyword.take(opts, [:plug]))) do
        {:ok, %{body: :too_large}} ->
          :rejected

        {:ok, %{status: status}} when status in [200, 202, 204] ->
          :accepted

        {:ok, %{status: status}} when status in [408, 429] or status >= 500 ->
          :unavailable

        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"error" => "HostBanned"}} -> :host_banned
            _ -> :rejected
          end

        {:error, _} ->
          :unavailable
      end

    :telemetry.execute([:atoll, :relay, :crawl], %{count: 1}, %{outcome: outcome})
    %{relay: origin, outcome: outcome}
  end

  defp validate(urls) when is_list(urls) and length(urls) in 0..10 do
    Enum.reduce_while(urls, {:ok, []}, fn value, {:ok, origins} ->
      case origin(value) do
        {:ok, url} -> {:cont, {:ok, origins ++ [url]}}
        _ -> {:halt, {:error, :relay_configuration_invalid}}
      end
    end)
    |> case do
      {:ok, origins} -> {:ok, Enum.uniq(origins)}
      error -> error
    end
  end

  defp validate(_), do: {:error, :relay_configuration_invalid}

  defp origin(value) when is_binary(value) and byte_size(value) <= 2048 do
    case URI.new(value) do
      {:ok,
       %URI{
         scheme: "https",
         host: host,
         port: 443,
         path: path,
         userinfo: nil,
         query: nil,
         fragment: nil
       }}
      when path in [nil, "", "/"] ->
        if valid_host?(host), do: {:ok, "https://" <> String.downcase(host)}, else: :error

      _ ->
        :error
    end
  end

  defp origin(_), do: :error

  defp hostname(url) do
    case origin(url) do
      {:ok, origin} -> URI.parse(origin).host
      _ -> nil
    end
  end

  defp valid_host?(host) when is_binary(host),
    do:
      match?(
        {:ok, _},
        Atoll.Identity.Resolver.resolution_url("did:web:" <> String.downcase(host))
      ) and Atoll.Syntax.handle?(host)

  defp valid_host?(_), do: false

  defp invalid!,
    do:
      raise(
        ArgumentError,
        "ATOLL_RELAY_URLS must contain at most ten HTTPS relay origins on port 443"
      )
end
