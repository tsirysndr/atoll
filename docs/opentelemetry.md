# OpenTelemetry

Atoll can export traces, logs and metrics to an OTLP collector over HTTP/protobuf.
Set `OTEL_EXPORTER_OTLP_ENDPOINT` in the service environment to enable all three.
Without it, no telemetry is exported. PostgreSQL and SQLite use the same integration.
For the systemd deployment, put these settings in `/etc/atoll/atoll.env`, which
the service already loads with `EnvironmentFile`. Restart Atoll after changes.

```sh
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
OTEL_SERVICE_NAME=atoll
DEPLOYMENT_ENVIRONMENT=production
OTEL_METRIC_EXPORT_INTERVAL=10000
# If the collector requires authentication, store this with the service secrets:
# OTEL_EXPORTER_OTLP_HEADERS=authorization=Bearer%20your-ingest-token
```

Use the collector's base URL; the exporters add `/v1/traces`, `/v1/logs` and
`/v1/metrics`. The SDK also accepts the standard per-signal endpoint, protocol,
and header overrides. `OTEL_RESOURCE_ATTRIBUTES` adds resource attributes and
`OTEL_SERVICE_NAME` overrides the default service name. All signals share the
service version, namespace (`rocksky`), deployment environment and per-boot instance ID.

Incoming W3C `traceparent` headers are continued. Every Bandit HTTP request gets
a server span, including requests handled by plugs before routing and WebSocket
upgrades. Upgrade spans finish when the handshake completes, not when the socket
closes. Database query spans are children of the current process's active span;
background queries are independent spans. This includes the optional read replica.

HTTP span and metric labels use matched route templates or fixed fallback groups.
Query strings, request/response bodies, headers, SQL, database URLs, query parameters
and database error messages are omitted. Existing Logger output at `info` or above
is copied to OTLP with trace/span IDs when an active span exists. Console logging
continues, and exporter-internal logs are excluded from OTLP to prevent feedback loops.
Application log messages retain their existing contents.

Metrics include:

| Name | Measurement |
| --- | --- |
| `http.server.requests` | Requests by route, method and status |
| `http.server.request.duration` | HTTP duration histogram in seconds |
| `atoll.database.queries` | Queries by database system and outcome |
| `atoll.database.query.duration` | Query duration histogram in seconds |
| `atoll.database.pool.wait` | Connection-pool wait histogram in seconds |
| `atoll.readiness.checks` | Ready/unavailable check counts |
| `erlang.vm.memory` | Bytes by memory area |
| `erlang.vm.process.count` | Live BEAM processes |
| `erlang.vm.run_queue` | Work waiting for a scheduler |

Metrics export every 10 seconds by default. Histogram exemplars link sampled
request measurements to their trace. The existing Prometheus `/metrics` endpoint
and its access controls remain available independently.

Tracing defaults to parent-based sampling with all root spans sampled. To reduce
volume, set `OTEL_TRACES_SAMPLER=parentbased_traceidratio` and
`OTEL_TRACES_SAMPLER_ARG=0.1`. Set `OTEL_SDK_DISABLED=true` and restart to disable
all signals. Collector failures do not change readiness or block serving requests;
telemetry export is asynchronous and best-effort. Metrics and logs use the Erlang
SDK's experimental API, with package versions pinned in `mix.lock`.

After restarting the service, request `/health/ready` and confirm that the
collector lists `atoll` with HTTP/database spans, correlated request logs and
metric points. Allow one export interval for metrics. Keep ingest credentials
in an environment file readable only by the service administrator.
