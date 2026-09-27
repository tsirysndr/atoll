defmodule Atoll.Telemetry do
  @moduledoc "OTLP traces, correlated Logger records and metrics; enabled by a collector endpoint."
  use GenServer
  require Logger
  require OpenTelemetry.Tracer, as: Tracer
  alias Atoll.Telemetry.Metrics

  @events [
    [:bandit, :request, :start],
    [:bandit, :request, :stop],
    [:bandit, :request, :exception],
    [:atoll, :repo, :query],
    [:atoll, :readiness, :check]
  ]
  @context_key {__MODULE__, :request_context}
  @methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS CONNECT TRACE)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    if Application.get_env(:atoll, :opentelemetry_enabled, false) do
      Metrics.setup()
      :telemetry.detach(__MODULE__)
      :ok = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.handle_event/4, nil)

      if Application.get_env(:atoll, :otlp_logs, false) do
        remove_log_handler()

        :ok =
          :logger.add_handler(:atoll_otlp, :otel_log_handler, %{
            level: :info,
            filter_default: :log,
            filters: [otel_internal: {&__MODULE__.filter_log/2, []}],
            exporter: {:otel_exporter_logs_otlp, %{}},
            scheduled_delay_ms: 5_000
          })
      end
    end

    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(__MODULE__)
    remove_log_handler()
    :ok
  end

  defp remove_log_handler do
    :logger.remove_handler(:atoll_otlp)

    # The experimental SDK removes the Logger registration separately from its
    # exporter process. Stop our own child too so application restarts work.
    if Process.whereis(:opentelemetry_experimental_sup),
      do: :supervisor.terminate_child(:opentelemetry_experimental_sup, :atoll_otlp)

    :ok
  end

  @doc false
  def handle_event([:bandit, :request, :start], _, %{conn: conn}, _) do
    # Each request starts from its incoming W3C context, including on keep-alive
    # connections. Save and restore the calling process's previous context.
    previous = :otel_ctx.get_current()
    incoming = :otel_propagator_text_map.extract_to(:otel_ctx.new(), conn.req_headers)
    token = :otel_ctx.attach(incoming)
    attributes = request_attributes(conn)
    span = Tracer.start_span(span_name(attributes), %{kind: :server, attributes: attributes})
    Tracer.set_current_span(span)
    Process.put(@context_key, {previous, token, span})
  end

  def handle_event([:bandit, :request, event], measurements, metadata, _)
      when event in [:stop, :exception] do
    case Process.delete(@context_key) do
      {previous, token, span} ->
        try do
          attributes = request_attributes(metadata[:conn])
          status = if event == :exception, do: 500, else: response_status(metadata[:conn])
          attributes = Map.put(attributes, :"http.response.status_code", status)
          OpenTelemetry.Span.set_attributes(span, attributes)
          OpenTelemetry.Span.update_name(span, span_name(attributes))

          if status >= 500,
            do:
              OpenTelemetry.Span.set_status(
                span,
                OpenTelemetry.status(:error, "HTTP server error")
              )

          Metrics.request(attributes, seconds(measurements[:duration]))
          OpenTelemetry.Span.end_span(span)
        after
          :otel_ctx.detach(token)
          :otel_tracer.update_logger_process_metadata(previous)
        end

      nil ->
        :ok
    end
  end

  def handle_event([:atoll, :repo, :query], measurements, metadata, _) do
    duration = measurements[:total_time] || 0
    failed = match?({:error, _}, metadata[:result])

    attributes = %{
      "db.system.name":
        Map.fetch!(%{postgres: "postgresql", sqlite: "sqlite"}, Atoll.Database.adapter()),
      "error.type": if(failed, do: "database_error", else: "none")
    }

    # Deliberately exclude SQL, parameters, connection URLs and exception text:
    # queries here include password hashes, sessions and signing key material.
    span =
      Tracer.start_span("database.query", %{
        kind: :client,
        start_time: :opentelemetry.timestamp() - duration,
        attributes: attributes
      })

    if failed,
      do:
        OpenTelemetry.Span.set_status(span, OpenTelemetry.status(:error, "Database query failed"))

    Metrics.database(attributes, seconds(duration), seconds(measurements[:queue_time]))
    OpenTelemetry.Span.end_span(span)
  end

  def handle_event([:atoll, :readiness, :check], _, metadata, _) do
    outcome = if metadata[:outcome] == :ready, do: "ready", else: "unavailable"
    Metrics.record(:"atoll.readiness.checks", 1, %{outcome: outcome})
  end

  def handle_event(_, _, _, _), do: :ok

  @doc false
  def request_attributes(nil), do: %{"http.request.method": "_OTHER", "http.route": "unmatched"}

  def request_attributes(conn) do
    method = if conn.method in @methods, do: conn.method, else: "_OTHER"

    route =
      case Phoenix.Router.route_info(AtollWeb.Router, conn.method, conn.request_path, conn.host) do
        %{route: route} -> route
        _ -> early_route(conn.request_path)
      end

    %{"http.request.method": method, "http.route": route}
  end

  # These endpoints are served by plugs before Phoenix's router.
  defp early_route("/xrpc/com.atproto.sync.subscribeRepos"),
    do: "/xrpc/com.atproto.sync.subscribeRepos"

  defp early_route("/oauth/" <> _), do: "/oauth/*"
  defp early_route("/account" <> _), do: "/account/*"
  defp early_route("/xrpc/" <> _), do: "/xrpc/*"
  defp early_route(_), do: "unmatched"

  defp span_name(attributes),
    do: attributes[:"http.request.method"] <> " " <> attributes[:"http.route"]

  defp response_status(%{status: status}) when is_integer(status), do: status
  defp response_status(_), do: 200
  defp seconds(nil), do: 0.0
  defp seconds(value), do: System.convert_time_unit(value, :native, :nanosecond) / 1_000_000_000

  @doc false
  def filter_log(%{meta: %{mfa: {module, _, _}}} = event, _) do
    if String.starts_with?(Atom.to_string(module), ["otel_", "opentelemetry"]),
      do: :stop,
      else: event
  end

  def filter_log(event, _), do: event
end
