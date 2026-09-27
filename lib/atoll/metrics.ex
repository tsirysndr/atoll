defmodule Atoll.Metrics do
  @moduledoc "Fixed-cardinality local Prometheus counters and progress gauges; no request or account metadata."
  use GenServer

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
        Map.take(state, [:counters, :indexes, :deadlines, :worker_indexes])
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
    add(state, :http_time, micros(measurements[:duration]))
  end

  def handle_event([:atoll, :repo, :query], measurements, _, state) do
    add(state, :queries, 1)
    add(state, :query_time, micros(measurements[:total_time]))
    add(state, :queue_time, micros(measurements[:queue_time]))
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
      exposition(gauges ++ deadlines ++ inventory, "gauge")
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
        "# TYPE ",
        name,
        " ",
        type,
        "\n",
        Enum.map(rows, fn {sample, value} -> [sample, " ", to_string(value), "\n"] end)
      ]
    end)
  end

  defp micros(n) when is_integer(n) and n >= 0,
    do: System.convert_time_unit(n, :native, :microsecond)

  defp micros(_), do: 0

  defp add(state, key, n) when is_integer(n) and n >= 0,
    do: :counters.add(state.counters, Map.fetch!(state.indexes, key), n)

  defp add(_, _, _), do: :ok
end
