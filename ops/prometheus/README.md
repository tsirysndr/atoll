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

## Validation

From the repository root:

```sh
bash scripts/test_monitoring.sh
```

The script uses Prometheus 3.5.0 `promtool` in a digest-pinned Docker image, pulling
it only if needed. It starts no service, exposes no ports, mounts the rule files
read-only, and disables networking inside each test container. No application
database or credentials are used. GitHub Actions runs the same check on pushes.

`alerts.test.yml` exercises firing delays, recovery, instance isolation, unrelated
jobs, low volume, idle and missing series, failed items, failed/timed-out runs,
duplicate suppression, counter resets, stalled progress, idle scheduling and
deadline resets, absent enabled workers, process-registration recovery and database
pool/total latency. These are synthetic rule tests, not a
live scrape or notification delivery test. With a compatible local `promtool`,
you can also run `promtool check rules alerts.yml` and
`promtool test rules alerts.test.yml` from this directory.
