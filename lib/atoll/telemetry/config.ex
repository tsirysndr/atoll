defmodule Atoll.Telemetry.Config do
  @moduledoc false

  def from_env!(env) do
    disabled =
      case Map.get(env, "OTEL_SDK_DISABLED", "false") do
        "true" -> true
        "false" -> false
        _ -> raise ArgumentError, "OTEL_SDK_DISABLED must be true or false"
      end

    endpoint = env["OTEL_EXPORTER_OTLP_ENDPOINT"]
    enabled = not disabled and endpoint not in [nil, ""]

    if enabled do
      case URI.parse(endpoint) do
        %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          :ok

        _ ->
          raise ArgumentError, "OTEL_EXPORTER_OTLP_ENDPOINT must be an HTTP(S) collector URL"
      end
    end

    interval =
      case Integer.parse(Map.get(env, "OTEL_METRIC_EXPORT_INTERVAL", "10000")) do
        {value, ""} when value >= 1000 -> value
        _ -> raise ArgumentError, "OTEL_METRIC_EXPORT_INTERVAL must be at least 1000 milliseconds"
      end

    %{
      enabled: enabled,
      endpoint: endpoint,
      interval: interval,
      environment: Map.get(env, "DEPLOYMENT_ENVIRONMENT", "production")
    }
  end
end
