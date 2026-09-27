defmodule Atoll.MetricsTest do
  use ExUnit.Case, async: false
  @collector __MODULE__.Collector

  setup do
    start_supervised!({Atoll.Metrics, name: @collector})
    :ok
  end

  test "exports fixed series and normalized duration units without sensitive metadata" do
    duration = System.convert_time_unit(2, :second, :native)

    :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: duration}, %{
      conn: %{status: 503, request_path: "/secret-account"}
    })

    :telemetry.execute([:atoll, :repo, :query], %{total_time: duration, queue_time: duration}, %{
      query: "secret SQL",
      params: ["password"]
    })

    :telemetry.execute([:atoll, :readiness, :check], %{count: 1}, %{outcome: :unavailable})

    :telemetry.execute([:atoll, :identity, :refresh], %{count: 1, failed: 3}, %{
      result: :failed,
      did: "did:plc:secret"
    })

    text = Atoll.Metrics.render(@collector)
    assert text =~ ~s(atoll_http_requests_total{status_class="5xx"} 1\n)
    assert text =~ "atoll_http_duration_seconds_total 2.0\n"
    assert text =~ "atoll_database_duration_seconds_total 2.0\n"
    assert text =~ ~s(atoll_readiness_checks_total{outcome="unavailable"} 1\n)
    assert text =~ ~s(atoll_worker_runs_total{worker="identity_refresh",result="failed"} 1\n)
    assert text =~ ~s(atoll_worker_items_failed_total{worker="identity_refresh"} 3\n)
    refute text =~ "secret"
    refute text =~ "password"
    assert String.ends_with?(text, "\n")
    samples = text |> String.split("\n", trim: true) |> Enum.reject(&String.starts_with?(&1, "#"))
    keys = Enum.map(samples, &(String.split(&1, " ") |> hd()))
    assert length(keys) == length(Enum.uniq(keys))
  end

  test "histograms retain inclusive boundaries, overflow and independent query timings" do
    boundary = System.convert_time_unit(1, :millisecond, :native)
    tail = System.convert_time_unit(12, :second, :native)

    for duration <- [0, boundary, boundary + 1, tail] do
      emit([:phoenix, :endpoint, :stop], %{duration: duration}, %{})
    end

    emit([:atoll, :repo, :query], %{total_time: tail, queue_time: boundary}, %{})
    emit([:atoll, :repo, :query], %{total_time: boundary}, %{})
    text = Atoll.Metrics.render(@collector)

    assert text =~ ~s(atoll_http_latency_seconds_bucket{le="0.001"} 2\n)
    assert text =~ ~s(atoll_http_latency_seconds_bucket{le="0.005"} 3\n)
    assert text =~ ~s(atoll_http_latency_seconds_bucket{le="10"} 3\n)
    assert text =~ ~s(atoll_http_latency_seconds_bucket{le="+Inf"} 4\n)
    assert text =~ "atoll_http_latency_seconds_count 4\n"

    expected_sum =
      Enum.sum(
        for n <- [boundary, boundary + 1, tail],
            do: System.convert_time_unit(n, :native, :microsecond)
      ) / 1_000_000

    assert text =~ "atoll_http_latency_seconds_sum #{expected_sum}\n"
    assert text =~ ~s(atoll_database_latency_seconds_bucket{le="0.001"} 1\n)
    assert text =~ ~s(atoll_database_latency_seconds_bucket{le="+Inf"} 2\n)
    assert text =~ "atoll_database_latency_seconds_count 2\n"
    assert text =~ "atoll_database_latency_seconds_sum 12.001\n"
    assert text =~ ~s(atoll_database_pool_wait_seconds_bucket{le="0.001"} 1\n)
    assert text =~ ~s(atoll_database_pool_wait_seconds_bucket{le="+Inf"} 1\n)
    assert text =~ "atoll_database_pool_wait_seconds_count 1\n"
    assert text =~ "atoll_database_pool_wait_seconds_sum 0.001\n"

    stop_supervised!(Atoll.Metrics)
    start_supervised!({Atoll.Metrics, name: @collector})
    reset = Atoll.Metrics.render(@collector)

    for name <-
          ~w(atoll_http_latency_seconds atoll_database_latency_seconds atoll_database_pool_wait_seconds) do
      assert reset =~ "#{name}_count 0\n"
      assert reset =~ "#{name}_sum 0.0\n"
      buckets = Regex.scan(~r/^#{name}_bucket\{le="[^"]+"\} (\d+)$/m, reset)
      assert length(buckets) == 13
      assert Enum.all?(buckets, fn [_, count] -> count == "0" end)
    end
  end

  test "invalid timings count events without inventing histogram observations" do
    for duration <- [nil, -1, "bad", 1.5] do
      emit([:phoenix, :endpoint, :stop], %{duration: duration}, %{})

      emit(
        [:atoll, :repo, :query],
        %{total_time: duration, queue_time: duration},
        %{}
      )
    end

    text = Atoll.Metrics.render(@collector)
    assert text =~ ~s(atoll_http_requests_total{status_class="unknown"} 4\n)
    assert text =~ "atoll_database_queries_total 4\n"

    for name <-
          ~w(atoll_http_latency_seconds atoll_database_latency_seconds atoll_database_pool_wait_seconds) do
      assert text =~ "#{name}_count 0\n"
      assert text =~ "#{name}_sum 0.0\n"
      assert text =~ ~s(#{name}_bucket{le="+Inf"} 0\n)
    end
  end

  test "unknown labels and invalid measurements cannot grow series cardinality" do
    before = Atoll.Metrics.render(@collector) |> String.split("\n") |> length()

    for n <- 1..100 do
      emit([:atoll, :blobs, :cleanup], %{failed: -1}, %{
        result: "hostile#{n}\"\n",
        did: "did:plc:#{n}"
      })
    end

    emit([:phoenix, :endpoint, :stop], %{duration: "bad"}, %{conn: %{status: 99999}})

    text = Atoll.Metrics.render(@collector)
    assert length(String.split(text, "\n")) == before
    assert text =~ ~s(atoll_worker_runs_total{worker="blob_cleanup",result="other"} 100\n)
    assert text =~ ~s(atoll_worker_items_failed_total{worker="blob_cleanup"} 0\n)
    refute text =~ "hostile"
    assert text =~ "atoll_http_duration_seconds_total 0.0\n"
  end

  test "restart replaces the telemetry handler and resets local counters" do
    :telemetry.execute([:atoll, :identity, :refresh], %{count: 1}, %{result: :ok})

    assert Atoll.Metrics.render(@collector) =~
             ~s(atoll_worker_runs_total{worker="identity_refresh",result="ok"} 1\n)

    stop_supervised!(Atoll.Metrics)
    start_supervised!({Atoll.Metrics, name: @collector})
    :telemetry.execute([:atoll, :identity, :refresh], %{count: 1}, %{result: :ok})

    assert Atoll.Metrics.render(@collector) =~
             ~s(atoll_worker_runs_total{worker="identity_refresh",result="ok"} 1\n)

    assert Enum.count(
             :telemetry.list_handlers([:atoll, :identity, :refresh]),
             &(&1.id == {Atoll.Metrics, @collector})
           ) == 1
  end

  test "exports worker-specific success outcomes without collapsing them into other" do
    for result <- [:published, :unchanged, :skipped] do
      :telemetry.execute([:atoll, :identity, :refresh], %{count: 1}, %{result: result})
    end

    :telemetry.execute([:atoll, :accounts, :signup_cleanup], %{runs: 1}, %{result: :ok})
    :telemetry.execute([:atoll, :oauth, :key_checks], %{runs: 1}, %{result: :complete})
    text = Atoll.Metrics.render(@collector)

    for result <- [:published, :unchanged, :skipped] do
      assert text =~ ~s(atoll_worker_runs_total{worker="identity_refresh",result="#{result}"} 1\n)
    end

    assert text =~ ~s(atoll_worker_runs_total{worker="signup_cleanup",result="ok"} 1\n)
    assert text =~ ~s(atoll_worker_runs_total{worker="oauth_key_checks",result="complete"} 1\n)
  end

  test "progress deadlines replace prior schedules without accepting arbitrary labels or values" do
    sample = ~s(atoll_worker_progress_deadline_seconds{worker="blob_cleanup"})
    assert Atoll.Metrics.render(@collector) =~ "#{sample} 0\n"

    for deadline <- [200, 100] do
      :telemetry.execute([:atoll, :worker, :scheduled], %{deadline_seconds: deadline}, %{
        worker: "blob_cleanup"
      })

      assert Atoll.Metrics.render(@collector) =~ "#{sample} #{deadline}\n"
    end

    for deadline <- [nil, "999", -1, 0, 9_223_372_036_854_775_808] do
      :telemetry.execute([:atoll, :worker, :scheduled], %{deadline_seconds: deadline}, %{
        worker: "blob_cleanup"
      })
    end

    :telemetry.execute([:atoll, :worker, :scheduled], %{deadline_seconds: 123}, %{
      worker: "secret-account"
    })

    text = Atoll.Metrics.render(@collector)
    assert text =~ "#{sample} 100\n"
    assert text =~ "# TYPE atoll_worker_progress_deadline_seconds gauge\n"
    refute text =~ "secret-account"
    assert length(Regex.scan(~r/^atoll_worker_progress_deadline_seconds\{/m, text)) == 8

    stop_supervised!(Atoll.Metrics)
    start_supervised!({Atoll.Metrics, name: @collector})
    assert Atoll.Metrics.render(@collector) =~ "#{sample} 0\n"
  end

  # Malformed synthetic timings must not detach unrelated production handlers.
  defp emit(event, measurements, metadata) do
    Atoll.Metrics.handle_event(event, measurements, metadata, :sys.get_state(@collector))
  end
end
