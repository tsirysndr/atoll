defmodule Atoll.TestTelemetryExporter do
  @moduledoc false
  def init(signal), do: {:ok, signal}
  def shutdown(_), do: :ok

  def export(_batch, _resource, :discard), do: :ok

  def export(batch, resource, signal) do
    payload =
      case signal do
        :metrics ->
          :otel_otlp_metrics.to_proto(batch, resource)

        :logs ->
          {logs, config} = batch
          :otel_otlp_logs.to_proto(logs, resource, config)
      end

    if pid = Process.whereis(__MODULE__), do: send(pid, {signal, payload})
    :ok
  end
end
