# Atoll alert rules

`alerts.yml` supplies baseline Prometheus alerts for the metrics described in the
project README. These are starting thresholds for operators to tune, not a full
production monitoring system. Rules select `job="atoll"` and evaluate each
instance independently. If you change the scrape job name, update every selector.

Enable Atoll metrics, configure the authenticated HTTPS scrape described in the
project README, copy `alerts.yml` onto the Prometheus host, and add its path to
your Prometheus configuration:

```yaml
rule_files:
  - /etc/prometheus/atoll-alerts.yml
```

Merge this with existing configuration; do not replace existing rule files or
scrape jobs. Validate the resulting configuration with `promtool check config`
before reloading Prometheus. This repository does not change a running deployment.
Configure your own Alertmanager targets, routing, receivers, silences and ownership
before relying on notifications. The rules alone do not deliver notifications.
Prometheus documents [alert rules and delivery](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/).

## Alerts and first checks

| Alert | Default condition | First checks |
| --- | --- | --- |
| `AtollScrapeUnavailable` | A configured Atoll scrape fails continuously for two minutes. | Inspect the Prometheus target error, network/TLS reachability, metrics enablement and Basic credentials. Check process liveness separately. This alert does not distinguish an application outage from an expired credential or monitoring failure. |
| `AtollHighServerErrorRate` | More than 5% of completed requests are 5xx over five minutes, with at least one request/second, sustained for five minutes. | Inspect application errors, database connectivity/pool saturation and recent changes. Tune the volume floor for small servers. |
| `AtollReadinessFailures` | At least half of recorded readiness probes fail over five minutes, sustained for two minutes. | Check PostgreSQL reachability and pool contention. Schedule regular `/health/ready` probes: scraping `/metrics` does not run readiness probes. |
| `AtollWorkerFailures` | At least one failed/timed-out worker run or failed item appears in the ten-minute counter increase. | Use the `worker` label to inspect the corresponding worker settings and dependencies. Check retry state and relevant external services before intervening. A successful retry does not immediately clear the historical failure window. |
| `AtollWorkerProgressOverdue` | An observed worker's scheduled progress deadline stays overdue for two minutes while `up=1`. | Inspect worker/supervisor state, mailbox congestion, VM pressure and database/dependency contention. Compare PDS and Prometheus clocks and account for intentional maintenance. |
| `AtollWorkerMissing` | A worker enabled in application configuration has no registered local process for two minutes while `up=1`. | Check supervisor failures, startup logs, enable flags and planned maintenance. The exporter does not start or restart workers. |
| `AtollDatabasePoolWait` | Mean pool queue time exceeds 100 ms per query over five minutes, at one or more queries/second, sustained for five minutes. | Check connection-pool demand, long transactions, global write-lock contention and PostgreSQL capacity. Increasing pool size alone can move contention into PostgreSQL. |
| `AtollDatabaseLatency` | Mean total Ecto query-event duration exceeds one second over five minutes, at one or more queries/second, sustained for five minutes. | Inspect pool wait, PostgreSQL locks/execution, network latency and result decoding. Total duration is broader than database server execution time. |

The delays above are pending periods after the expression first becomes true;
rolling windows add recovery lag. Counters are processed with `rate()`/`increase()`
before aggregation so a node restart does not create an artificial error spike.
Worker run and item failures for the same worker produce one alert, while failures
in different workers stay separate. HTTP totals include completed scrapes and
probes, and exclude requests without an endpoint stop event. Low-volume HTTP
errors can intentionally stay below the alert floor.

Database latency rules use per-instance rates of accumulated seconds divided by
query-event rates, with counter-reset handling before aggregation. They include
failed query events reported by Ecto, expose no SQL/account labels, and measure
means rather than tail percentiles. Both can fire when pool wait also raises total
duration. Tune the one-query/second floor and thresholds for small or bursty PDS
deployments; low-volume latency, completely stuck requests without query telemetry,
and missing timing series do not trigger these alerts. Use readiness, scrape and
database-side monitoring alongside them. The supplied tests cover high latency,
healthy-instance isolation, recovery, sparse/idle/missing series and counter resets.

Missing readiness/worker series or an idle worker do not trigger a failure alert.
Disabled workers emit no completion events. A removed scrape target disappears
instead of setting `up=0`; use an independent inventory or absent-series rule for
your expected deployment. These rules do not detect Prometheus itself stopping,
registered workers stuck without a progress observation, missing probes, disk exhaustion, stale backups, or failures in
dependencies not represented by these counters. Test your notification path and
cover those gaps separately.

Progress deadlines come from each scheduler's actual next delay plus task timeout,
including startup delays and empty-work rescheduling. They are not last-success
timestamps or proof that a queue is draining. An overdue-progress alert retains
the worker and instance labels, ignores zero/missing deadlines and unrelated jobs,
and defers to scrape-unavailable alerting when the target is down. Rescheduling
clears it without a historical failure window. Progress timestamps use wall time;
clock skew or clock jumps can affect this rule. Keep clocks synchronized.

The collector initializes each deadline to zero and forgets observations on its
own restart. Worker expectation and presence are read independently at scrape
time, so an enabled but absent worker remains detectable across collector restarts
and needs no previous progress event. Missing expectation/presence series do not
trigger this rule; monitor exporter/version coverage separately. A registered
process is not proof of health: a process stuck across collector restart cannot
be diagnosed from zero progress deadlines alone. Stopping an observed worker without resetting the
collector leaves its last deadline; use planned-maintenance silences as needed.

Expectations follow the current application enable flags and nested signup/OAuth
worker configuration, using the same defaults as supervision. Editing those values
does not itself reconcile child processes. Presence checks inspect fixed local
registered names and never send worker messages or query PostgreSQL. They can
report a blocked or suspended process as present; use the progress alert alongside
this inventory check. Both gauges keep the eight fixed worker labels and expose
no process IDs, account identifiers or configuration secrets.

## Cleanup backlog and inventory freshness

Metrics-enabled nodes sample PostgreSQL's blob cleanup queue every ten seconds,
with bounded lock, statement and client timeouts. The scrape itself reads only
cached inventory. `config :atoll, :metrics_database_polling_enabled, false` disables
these polls independently. Counts and oldest timestamps have only `postgres` and
`s3` labels. They measure cleanup jobs, not bytes that can safely be deleted.
A shared database produces duplicate observations across PDS nodes; do not sum
those counts across replicas. Poll failures preserve the old snapshot, so gate
queries on availability and a recent success timestamp.

`AtollDatabaseInventoryUnavailable` fires after two minutes when enabled polling
has failed or its last success is older than two minutes, while `up=1`. Check
database reachability, pool pressure, queue size, lock contention and the telemetry
poller. It also detects a stopped poller whose last attempt succeeded. A collector
restart sets availability and last success to zero until a new poll succeeds.
Disabled polling suppresses the alert. Missing series are not inventory of expected
servers; use separate exporter/version coverage checks.

`AtollBlobCleanupBacklog` fires per backend after a job remains more than 24 hours
old for five minutes, using only successful observations at most two minutes old.
Check cleanup worker enablement/progress, recent failed-item counters, S3
connectivity and object ownership before running manual collection. Intentionally
scheduled manual cleanup may warrant a different age threshold. Empty queues,
failed/stale inventory, disabled polling and failed scrapes suppress this alert.
Stale inventory has its own alert; clearing the backlog alert alone is not proof
that jobs were deleted. These timestamps depend on synchronized clocks.

## Latency percentiles

For per-instance completed HTTP request p95 over five minutes:

```promql
histogram_quantile(0.95,
  sum by (job, instance, le) (
    rate(atoll_http_latency_seconds_bucket{job="atoll"}[5m])
  )
)
```

Use `atoll_database_latency_seconds_bucket` for total Ecto duration or
`atoll_database_pool_wait_seconds_bucket` for pool waits. Apply `rate()` before
aggregation to handle collector resets. These fixed classic histograms estimate
quantiles within buckets; they do not store individual samples. Sparse traffic
can produce unstable estimates and an empty observation window yields NaN.
The highest finite bound is ten seconds: the +Inf bucket and sum retain longer
observations, but a quantile in that bucket resolves to the ten-second bound,
not the actual tail duration. There are no route, SQL or account labels.
See Prometheus's [histogram guidance](https://prometheus.io/docs/practices/histograms/).
The existing database alerts continue to use means; this query does not add a
percentile alert or dashboard automatically.

## Validation

With Docker, Elixir/Erlang and the project Mix dependencies installed, run from the repository root:

```sh
bash scripts/test_monitoring.sh
```

The script uses Prometheus 3.5.0 `promtool` in a digest-pinned Docker image, pulling
it only if needed. It starts no service, exposes no ports, mounts the rule files
read-only, and disables networking inside each test container. No application
database or credentials are used. It also compiles in the test environment and
runs `scripts/metrics_fixture.exs` with `mix run --no-start`: only telemetry and
the collector start, without Repo, the endpoint or background workers. Synthetic
timings exercise zero durations, finite buckets and overflow. The actual emitted
text passes through `promtool check metrics` to validate metric metadata and
exposition framing. GitHub Actions runs the same checks on pushes.

`alerts.test.yml` exercises firing delays, recovery, instance isolation, unrelated
jobs, low volume, idle and missing series, failed items, failed/timed-out runs,
duplicate suppression, counter resets, stalled progress, idle scheduling and
deadline resets, absent enabled workers, process-registration recovery and database
pool/total latency, inventory failure/staleness and aged blob cleanup queues.
These are synthetic rule tests, not a
live scrape or notification delivery test. With a compatible local `promtool`,
you can also run `promtool check rules alerts.yml` and
`promtool test rules alerts.test.yml` from this directory.
