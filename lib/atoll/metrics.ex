defmodule Atoll.Metrics do
  @moduledoc "Fixed-cardinality local Prometheus counters, histograms and gauges; no request or account metadata."
  use GenServer

  @help %{
    "atoll_http_duration_seconds_total" =>
      "Accumulated completed HTTP request duration in seconds.",
    "atoll_database_duration_seconds_total" =>
      "Accumulated total Ecto query-event duration in seconds.",
    "atoll_database_queue_seconds_total" =>
      "Accumulated Ecto connection-pool queue time in seconds.",
    "atoll_database_queries_total" => "Ecto query events including reported failures.",
    "atoll_http_requests_total" => "Completed HTTP requests by status class.",
    "atoll_readiness_checks_total" => "Database readiness checks by outcome.",
    "atoll_worker_runs_total" => "Background worker completion events by worker and result.",
    "atoll_worker_items_failed_total" => "Failed items reported by background workers.",
    "atoll_collector_start_time_seconds" => "Unix timestamp of this collector start.",
    "atoll_vm_memory_bytes" => "Total Erlang VM memory in bytes.",
    "atoll_vm_run_queue" => "Current Erlang VM run queue length.",
    "atoll_worker_progress_deadline_seconds" =>
      "Expected next worker progress as Unix seconds; zero means unobserved.",
    "atoll_worker_expected" => "Whether application configuration enables the standard worker.",
    "atoll_worker_present" => "Whether the standard worker has a registered local process.",
    "atoll_http_latency_seconds" =>
      "Distribution of valid completed HTTP request durations in seconds.",
    "atoll_database_latency_seconds" =>
      "Distribution of valid total Ecto query-event durations in seconds.",
    "atoll_database_pool_wait_seconds" =>
      "Distribution of valid Ecto connection-pool waits in seconds."
  }
  @workers %{
    [:atoll, :identity, :refresh] => "identity_refresh",
    [:atoll, :blobs, :cleanup] => "blob_cleanup",
    [:atoll, :accounts, :cleanup] => "account_cleanup",
    [:atoll, :accounts, :signup_cleanup] => "signup_cleanup",
    [:atoll, :accounts, :signup_retry] => "signup_retry",
    [:atoll, :oauth, :key_checks] => "oauth_key_checks",
    [:atoll, :events, :retention] => "event_retention",
    [:atoll, :relay, :announcement] => "relay_announcement"
  }
  @buckets [
    {1000, "0.001"},
    {5000, "0.005"},
    {10_000, "0.01"},
    {25_000, "0.025"},
    {50_000, "0.05"},
    {100_000, "0.1"},
    {250_000, "0.25"},
    {500_000, "0.5"},
    {1_000_000, "1"},
    {2_500_000, "2.5"},
    {5_000_000, "5"},
    {10_000_000, "10"}
  ]
  @histograms [
    {:http_time, "atoll_http_latency_seconds"},
    {:query_time, "atoll_database_latency_seconds"},
    {:queue_time, "atoll_database_pool_wait_seconds"}
  ]
  @outcomes ~w(ok complete completed published unchanged skipped failed timeout other)a
  @classes ~w(1xx 2xx 3xx 4xx 5xx unknown)
  @events [
            [:phoenix, :endpoint, :stop],
            [:atoll, :repo, :query],
            [:atoll, :readiness, :check],
            [:atoll, :worker, :scheduled]
          ] ++
            Map.keys(@workers)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def render(server \\ __MODULE__), do: GenServer.call(server, :render, 1_000)
  def enabled_from_env!("true"), do: true
  def enabled_from_env!("false"), do: false

  def enabled_from_env!(_),
    do: raise(ArgumentError, "ATOLL_METRICS_ENABLED must be true or false")

  @impl true
  def init(opts) do
    definitions = definitions()
    indexes = definitions |> Enum.with_index(1) |> Map.new(fn {{key, _, _}, n} -> {key, n} end)

    state = %{
      histograms:
        Map.new(@histograms, fn {key, _} ->
          {key, :counters.new(length(@buckets) + 1, [:write_concurrency])}
        end),
      deadlines: :atomics.new(map_size(@workers), []),
      worker_indexes: @workers |> Map.values() |> Enum.sort() |> Enum.with_index(1) |> Map.new(),
      counters: :counters.new(length(definitions), [:write_concurrency]),
      indexes: indexes,
      definitions: definitions,
      started: System.system_time(:second),
      handler: {__MODULE__, Keyword.get(opts, :name, __MODULE__)}
    }

    :telemetry.detach(state.handler)

    :ok =
      :telemetry.attach_many(
        state.handler,
        @events,
        &__MODULE__.handle_event/4,
        Map.take(state, [:counters, :indexes, :deadlines, :worker_indexes, :histograms])
      )

    {:ok, state}
  end

  @doc false
  def handle_event([:phoenix, :endpoint, :stop], measurements, metadata, state) do
    status =
      case metadata do
        %{conn: %{status: value}} when value in 100..599 -> "#{div(value, 100)}xx"
        _ -> "unknown"
      end

    add(state, {:http, status}, 1)
    observe(state, :http_time, measurements[:duration])
  end

  def handle_event([:atoll, :repo, :query], measurements, _, state) do
    add(state, :queries, 1)
    observe(state, :query_time, measurements[:total_time])
    observe(state, :queue_time, measurements[:queue_time])
  end

  def handle_event([:atoll, :readiness, :check], _, metadata, state) do
    result = if metadata[:outcome] in [:ready, :unavailable], do: metadata[:outcome], else: :other
    add(state, {:readiness, result}, 1)
  end

  def handle_event([:atoll, :worker, :scheduled], measurements, metadata, state) do
    with {:ok, index} <- Map.fetch(state.worker_indexes, metadata[:worker]),
         deadline
         when is_integer(deadline) and deadline > 0 and deadline <= 9_223_372_036_854_775_807 <-
           measurements[:deadline_seconds] do
      :atomics.put(state.deadlines, index, deadline)
    else
      _ -> :ok
    end
  end

  def handle_event(event, measurements, metadata, state) do
    case @workers[event] do
      nil ->
        :ok

      worker ->
        result = if metadata[:result] in @outcomes, do: metadata[:result], else: :other
        add(state, {:worker, worker, result}, 1)
        add(state, {:failed_items, worker}, measurements[:failed])
    end
  end

  @impl true
  def handle_call(:render, _, state) do
    counters =
      Enum.map(state.definitions, fn {key, sample, scale} ->
        value = :counters.get(state.counters, Map.fetch!(state.indexes, key))
        {sample, if(scale == 1, do: value, else: value / scale)}
      end)

    gauges = [
      {"atoll_collector_start_time_seconds", state.started},
      {"atoll_vm_memory_bytes", :erlang.memory(:total)},
      {"atoll_vm_run_queue", :erlang.statistics(:run_queue)}
    ]

    deadlines =
      Enum.map(state.worker_indexes, fn {worker, index} ->
        {~s(atoll_worker_progress_deadline_seconds{worker="#{worker}"}),
         :atomics.get(state.deadlines, index)}
      end)

    inventory =
      Enum.flat_map(Atoll.WorkerProgress.inventory(), fn row ->
        [
          {~s(atoll_worker_expected{worker="#{row.worker}"}), row.expected},
          {~s(atoll_worker_present{worker="#{row.worker}"}), row.present}
        ]
      end)

    output = [
      exposition(counters, "counter"),
      exposition(gauges ++ deadlines ++ inventory, "gauge"),
      histograms(state)
    ]

    {:reply, IO.iodata_to_binary(output), state}
  end

  @impl true
  def terminate(_, state), do: :telemetry.detach(state.handler)

  defp definitions do
    [
      {:http_time, "atoll_http_duration_seconds_total", 1_000_000},
      {:queries, "atoll_database_queries_total", 1},
      {:query_time, "atoll_database_duration_seconds_total", 1_000_000},
      {:queue_time, "atoll_database_queue_seconds_total", 1_000_000}
    ] ++
      Enum.map(@classes, &{{:http, &1}, ~s(atoll_http_requests_total{status_class="#{&1}"}), 1}) ++
      Enum.map(
        [:ready, :unavailable, :other],
        &{{:readiness, &1}, ~s(atoll_readiness_checks_total{outcome="#{&1}"}), 1}
      ) ++
      for(
        worker <- Enum.sort(Map.values(@workers)),
        result <- @outcomes,
        do:
          {{:worker, worker, result},
           ~s(atoll_worker_runs_total{worker="#{worker}",result="#{result}"}), 1}
      ) ++
      Enum.map(
        Enum.sort(Map.values(@workers)),
        &{{:failed_items, &1}, ~s(atoll_worker_items_failed_total{worker="#{&1}"}), 1}
      )
  end

  defp exposition(samples, type) do
    samples
    |> Enum.group_by(fn {sample, _} -> sample |> String.split("{", parts: 2) |> hd() end)
    |> Enum.sort()
    |> Enum.map(fn {name, rows} ->
      [
        metadata(name, type),
        Enum.map(rows, fn {sample, value} -> [sample, " ", to_string(value), "\n"] end)
      ]
    end)
  end

  defp observe(state, key, native) when is_integer(native) and native >= 0 do
    micros = System.convert_time_unit(native, :native, :microsecond)
    add(state, key, micros)
    # One noncumulative bin per observation; render cumulative buckets from one
    # bounded read of each bin so +Inf and count always agree within a scrape.
    index =
      Enum.find_index(@buckets, fn {bound, _} ->
        native <= System.convert_time_unit(bound, :microsecond, :native)
      end) || length(@buckets)

    :counters.add(Map.fetch!(state.histograms, key), index + 1, 1)
  end

  defp observe(_, _, _), do: :ok

  defp histograms(state) do
    Enum.map(@histograms, fn {key, name} ->
      bins = Map.fetch!(state.histograms, key)
      labels = Enum.map(@buckets, &elem(&1, 1)) ++ ["+Inf"]

      {rows, count} =
        labels
        |> Enum.with_index(1)
        |> Enum.map_reduce(0, fn {label, index}, count ->
          count = count + :counters.get(bins, index)
          {[name, "_bucket{le=\"", label, "\"} ", Integer.to_string(count), "\n"], count}
        end)

      sum = :counters.get(state.counters, Map.fetch!(state.indexes, key)) / 1_000_000

      [
        metadata(name, "histogram"),
        rows,
        name,
        "_sum ",
        to_string(sum),
        "\n",
        name,
        "_count ",
        Integer.to_string(count),
        "\n"
      ]
    end)
  end

  defp metadata(name, type),
    do: ["# HELP ", name, " ", Map.fetch!(@help, name), "\n# TYPE ", name, " ", type, "\n"]

  defp add(state, key, n) when is_integer(n) and n >= 0,
    do: :counters.add(state.counters, Map.fetch!(state.indexes, key), n)

  defp add(_, _, _), do: :ok
end
