defmodule Atoll.Redis do
  @moduledoc "Optional Redis connection for shared request budgets; disabled with the default memory backend."

  def config!(env, backend) do
    if backend == :redis do
      url = env["ATOLL_REDIS_URL"]
      namespace = Map.get(env, "ATOLL_REDIS_NAMESPACE", "atoll")
      uri = if is_binary(url), do: URI.new(url), else: :error

      unless match?(
               {:ok, %URI{scheme: scheme, host: host, query: nil, fragment: nil}}
               when scheme in ["redis", "rediss"] and is_binary(host) and host != "",
               uri
             ) and
               is_binary(namespace) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, namespace),
             do:
               raise(
                 "Redis requires ATOLL_REDIS_URL (redis:// or rediss://) and a valid ATOLL_REDIS_NAMESPACE"
               )

      [url: url, namespace: namespace]
    else
      []
    end
  end

  def children do
    if Application.get_env(:atoll, :rate_limit_backend, :memory) == :redis do
      config = Application.fetch_env!(:atoll, :redis)
      [{Redix, {Keyword.fetch!(config, :url), [name: __MODULE__, timeout: 2000]}}]
    else
      []
    end
  end
end
