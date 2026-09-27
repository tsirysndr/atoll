defmodule Atoll.Telemetry.Metrics do
  @moduledoc false

  def setup do
    meter = meter()

    for name <- [:"http.server.requests", :"atoll.database.queries", :"atoll.readiness.checks"] do
      :otel_meter.create_counter(meter, name, %{})
    end

    for name <- [
          :"http.server.request.duration",
          :"atoll.database.query.duration",
          :"atoll.database.pool.wait"
        ] do
      :otel_meter.create_histogram(meter, name, %{
        unit: :s,
        advisory_params: %{
          explicit_bucket_boundaries: [
            0.001,
            0.005,
            0.01,
            0.025,
            0.05,
            0.1,
            0.25,
            0.5,
            1.0,
            2.5,
            5.0,
            10.0
          ]
        }
      })
    end

    :otel_meter.create_observable_gauge(meter, :"erlang.vm.memory", &__MODULE__.memory/1, [], %{
      unit: :By
    })

    :otel_meter.create_observable_gauge(
      meter,
      :"erlang.vm.process.count",
      &__MODULE__.processes/1,
      [],
      %{}
    )

    :otel_meter.create_observable_gauge(
      meter,
      :"erlang.vm.run_queue",
      &__MODULE__.run_queue/1,
      [],
      %{}
    )

    :ok
  end

  def request(attributes, seconds) do
    record(:"http.server.requests", 1, attributes)
    record(:"http.server.request.duration", seconds, attributes)
  end

  def database(attributes, seconds, queue_seconds) do
    record(:"atoll.database.queries", 1, attributes)
    record(:"atoll.database.query.duration", seconds, attributes)
    record(:"atoll.database.pool.wait", queue_seconds, attributes)
  end

  def record(name, value, attributes),
    do: :otel_meter.record(:otel_ctx.get_current(), meter(), name, value, attributes)

  def memory(_) do
    memory = :erlang.memory()

    for area <- [:total, :processes, :binary, :ets],
        do: {memory[area], %{"erlang.memory.area": Atom.to_string(area)}}
  end

  def processes(_), do: [{:erlang.system_info(:process_count), %{}}]
  def run_queue(_), do: [{:erlang.statistics(:total_run_queue_lengths_all), %{}}]

  defp meter do
    :opentelemetry_experimental.get_meter(
      :opentelemetry.instrumentation_scope("atoll", "0.1.0", :undefined)
    )
  end
end
