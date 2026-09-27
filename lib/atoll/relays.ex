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

  def schedule_from_env!(env, test? \\ false) do
    enabled =
      case Map.get(env, "ATOLL_RELAY_CRAWL_ENABLED", "false") do
        "true" -> true
        "false" -> false
        _ -> raise ArgumentError, "ATOLL_RELAY_CRAWL_ENABLED must be true or false"
      end

    interval =
      case Integer.parse(Map.get(env, "ATOLL_RELAY_CRAWL_INTERVAL_SECONDS", "900")) do
        {seconds, ""} when seconds in 300..86_400 ->
          seconds

        _ ->
          raise ArgumentError,
                "ATOLL_RELAY_CRAWL_INTERVAL_SECONDS must be an integer from 300 to 86400"
      end

    if enabled and from_env!(env["ATOLL_RELAY_URLS"]) == [],
      do: raise(ArgumentError, "ATOLL_RELAY_CRAWL_ENABLED requires ATOLL_RELAY_URLS")

    %{enabled: enabled and not test?, interval_seconds: interval}
  end

  def request_crawl(opts \\ []) do
    with {:ok, origins, host} <- configured_batch(opts),
         do: {:ok, Enum.map(origins, &request(&1, host, opts))}
  end

  @doc "Operator crawl announcement with durable attempt and completion history."
  def request_crawl_audited(opts \\ []) do
    if Atoll.Repo.in_transaction?(),
      do: {:error, :relay_audit_transaction},
      else: audited_request_crawl(opts)
  end

  defp audited_request_crawl(opts) do
    with {:ok, origins, host} <- configured_batch(opts),
         {:ok, attempt} <-
           audit(fn -> Atoll.Moderation.Audit.relay_crawl_attempt!(host, origins) end) do
      # Do not hold database locks during network requests. An interrupted batch
      # leaves an attempt without a completion, not a claim of remote failure.
      results = Enum.map(origins, &request(&1, host, opts))

      case audit(fn ->
             Atoll.Moderation.Audit.relay_crawl_completed!(attempt.id, host, results)
           end) do
        {:ok, _} -> {:ok, results}
        {:error, _} -> {:error, :relay_outcome_audit_unavailable}
      end
    end
  end

  defp audit(function) do
    Atoll.Repo.transaction(fn ->
      Atoll.Repo.query!("SET LOCAL lock_timeout = '1s'")
      Atoll.Repo.query!("SET LOCAL statement_timeout = '5s'")
      function.()
    end)
  rescue
    _ in [Postgrex.Error, DBConnection.ConnectionError, Ecto.ConstraintError] ->
      {:error, :relay_audit_unavailable}
  end

  defp configured_batch(opts) do
    urls = Application.get_env(:atoll, :relay_urls, [])
    hostname = Keyword.get_lazy(opts, :hostname, fn -> hostname(AtollWeb.Endpoint.url()) end)

    with {:ok, origins} <- validate(urls),
         true <- origins != [],
         true <- valid_host?(hostname) do
      {:ok, origins, String.downcase(hostname)}
    else
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
