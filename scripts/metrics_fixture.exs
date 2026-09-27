# Offline synthetic exposition for promtool. Never start Atoll or its database.
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, collector} = Atoll.Metrics.start_link([])

for micros <- [0, 1000, 9999, 2_500_000, 12_000_000] do
  native = System.convert_time_unit(micros, :microsecond, :native)
  :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: native}, %{conn: %{status: 200}})
  :telemetry.execute([:atoll, :repo, :query], %{total_time: native, queue_time: native}, %{})
end

Atoll.Metrics.Firehose.sample(fn ->
  {:ok, %{active: 12, pending: 2, max_connections: 1024, max_connections_per_ip: 16}}
end)

for outcome <- [:accepted, :full, :unavailable] do
  :telemetry.execute([:atoll, :firehose, :admission], %{count: 1}, %{outcome: outcome})
end

IO.write(Atoll.Metrics.render(collector))
GenServer.stop(collector)
