defmodule Atoll.TelemetryTest do
  use Atoll.DataCase, async: false
  require Record
  require OpenTelemetry.Tracer, as: Tracer
  alias Atoll.Telemetry

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  setup do
    Process.register(self(), Atoll.TestTelemetryExporter)
    :ok = :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    on_exit(fn -> :otel_simple_processor.set_exporter(Atoll.TestTelemetryExporter, :discard) end)
    :ok
  end

  test "real HTTP requests export parented database traces, correlated logs and metrics" do
    :ok =
      :logger.add_handler(:atoll_test_otlp, :otel_log_handler, %{
        level: :warning,
        exporter: {Atoll.TestTelemetryExporter, :logs},
        scheduled_delay_ms: 20
      })

    on_exit(fn ->
      :logger.remove_handler(:atoll_test_otlp)
      :supervisor.terminate_child(:opentelemetry_experimental_sup, :atoll_test_otlp)
    end)

    server =
      start_supervised!({Bandit, plug: Atoll.TestTelemetryPlug, port: 0, ip: {127, 0, 0, 1}})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    trace_id = "12345678901234567890123456789012"
    parent_id = "1234567890123456"

    assert %{status: 200} =
             Req.get!("http://127.0.0.1:#{port}/health?token=do-not-export",
               headers: [
                 traceparent: "00-#{trace_id}-#{parent_id}-01",
                 authorization: "Bearer do-not-export"
               ]
             )

    assert_receive {:span, query}, 2_000
    assert span(query, :name) == "database.query"
    assert_receive {:span, request}, 2_000
    assert span(request, :name) == "GET /health"
    assert span(request, :trace_id) == String.to_integer(trace_id, 16)
    assert span(request, :parent_span_id) == String.to_integer(parent_id, 16)
    assert span(query, :trace_id) == span(request, :trace_id)
    assert span(query, :parent_span_id) == span(request, :span_id)
    refute inspect([query, request]) =~ "do-not-export"
    refute inspect(query) =~ "SELECT 1"

    assert_receive {:logs, %{resource_logs: [resource]}}, 2_000
    logs = Enum.flat_map(resource.scope_logs, & &1.log_records)
    log = Enum.find(logs, &(&1.body == %{value: {:string_value, "telemetry integration check"}}))
    assert log
    assert log.trace_id == Base.decode16!(trace_id, case: :mixed)
    assert log.span_id == <<span(request, :span_id)::unsigned-big-64>>

    :ok = :otel_meter_server.force_flush()
    assert_receive {:metrics, %{resource_metrics: [resource]}}, 2_000
    metrics = Enum.flat_map(resource.scope_metrics, & &1.metrics)
    names = Enum.map(metrics, & &1.name)
    assert "http.server.requests" in names
    assert "http.server.request.duration" in names
    assert "atoll.database.query.duration" in names
    assert "erlang.vm.memory" in names
    refute inspect(metrics) =~ "do-not-export"

    # A later request without traceparent must not inherit the first request.
    assert %{status: 503} = Req.get!("http://127.0.0.1:#{port}/error", retry: false)
    assert_receive {:span, _query}, 2_000
    assert_receive {:span, request2}, 2_000
    refute span(request2, :trace_id) == span(request, :trace_id)
    assert {:status, :error, _} = span(request2, :status)
  end

  test "exception completion restores the calling context and omits exception secrets" do
    previous = Tracer.start_span("outer")
    Tracer.set_current_span(previous)
    conn = Plug.Test.conn(:get, "/oauth/authorize?token=secret")
    Telemetry.handle_event([:bandit, :request, :start], %{}, %{conn: conn}, nil)

    Telemetry.handle_event(
      [:bandit, :request, :exception],
      %{duration: 1},
      %{conn: conn, reason: "secret"},
      nil
    )

    assert_receive {:span, failed}
    assert {:status, :error, _} = span(failed, :status)
    refute inspect(failed) =~ "secret"
    assert Tracer.current_span_ctx() == previous
    OpenTelemetry.Span.end_span(previous)
    :otel_ctx.clear()
    :otel_tracer.update_logger_process_metadata(%{})
  end

  test "SDK export errors are excluded from the log export loop" do
    assert Telemetry.filter_log(%{meta: %{mfa: {:otel_exporter_traces_otlp, :export, 3}}}, []) ==
             :stop

    event = %{meta: %{mfa: {Atoll.Accounts, :test, 0}}}
    assert Telemetry.filter_log(event, []) == event
  end
end
