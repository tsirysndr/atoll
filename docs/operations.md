# Operations

Monitoring, rate limits, retention, relays, proxy routing, maintenance mode, and production behavior.

### Prometheus monitoring

Set `ATOLL_METRICS_ENABLED=true` or `config :atoll, :metrics_enabled, true`
to expose `GET /metrics`. It is disabled by default (HTTP 404). An explicitly
set environment variable overrides application configuration and accepts only
`true` or `false`; invalid values fail startup. When enabled, the endpoint uses
the existing operator HTTP Basic credentials: username `admin` and the configured
`ATOLL_ADMIN_PASSWORD`. Missing or incorrect credentials return 401; missing
operator configuration or an unavailable collector returns 503. Responses disable
caching. Use HTTPS when scraping across a network and protect the credential file:
these credentials also grant administrative access.

Example [Prometheus scrape configuration](https://prometheus.io/docs/prometheus/latest/configuration/configuration/)
(replace the hostname and secret path):

```yaml
scrape_configs:
  - job_name: atoll
    scheme: https
    metrics_path: /metrics
    scrape_interval: 30s
    basic_auth:
      username: admin
      password_file: /run/secrets/atoll_admin_password
    static_configs:
      - targets: [pds.example.com:443]
```

The endpoint serves [Prometheus text format 0.0.4](https://prometheus.io/docs/instrumenting/exposition_formats/)
and collects these metric families:

| Metric | Meaning |
| --- | --- |
| `atoll_http_requests_total` | Completed Phoenix endpoint requests, labeled only by HTTP status class. |
| `atoll_http_duration_seconds_total` | Accumulated completed endpoint duration in seconds. |
| `atoll_database_queries_total` | Ecto query telemetry events, including failed queries. |
| `atoll_database_duration_seconds_total` | Accumulated Ecto total query duration in seconds. |
| `atoll_database_queue_seconds_total` | Accumulated database pool queue duration in seconds. |
| `atoll_http_latency_seconds` | Classic histogram of completed endpoint durations. |
| `atoll_database_latency_seconds` | Classic histogram of total Ecto query-event durations. |
| `atoll_database_pool_wait_seconds` | Classic histogram of Ecto connection-pool waits. |
| `atoll_readiness_checks_total` | Readiness checks labeled by `ready`, `unavailable`, or `other`. |
| `atoll_worker_runs_total` | Worker completion events labeled by a fixed worker name and result. |
| `atoll_worker_items_failed_total` | Worker-reported failed item counts, separate from failed or timed-out runs. |
| `atoll_worker_progress_deadline_seconds` | Expected next scheduler progress, as Unix seconds, labeled by fixed worker name; zero means not yet observed since collector startup. |
| `atoll_worker_expected` | Whether current application configuration enables each standard worker (1 or 0). |
| `atoll_worker_present` | Whether each standard worker has a locally registered process (1 or 0). |
| `atoll_collector_start_time_seconds` | Collector start time as Unix seconds. |
| `atoll_vm_memory_bytes` | Current total Erlang VM memory. |
| `atoll_vm_run_queue` | Current Erlang run queue length. |
| `atoll_firehose_admissions_total{outcome}` | Upgrade admissions: `accepted`, `full`, or `unavailable`. |
| `atoll_firehose_inventory_available` | Whether the latest live-connection snapshot succeeded. |
| `atoll_firehose_inventory_success_time_seconds` | Last successful snapshot time; zero means unobserved. |
| `atoll_firehose_active` / `atoll_firehose_pending` | Claimed streams and pending upgrades at the last successful snapshot. |
| `atoll_firehose_max_connections` / `atoll_firehose_max_connections_per_ip` | Last observed node and per-IP quotas. |
| `atoll_database_inventory_enabled` | Whether periodic database inventory is enabled (1 or 0). |
| `atoll_database_inventory_available` | Whether the latest inventory poll succeeded (1 or 0); initially 0. |
| `atoll_database_inventory_success_time_seconds` | Last successful inventory timestamp; initially 0. |
| `atoll_blob_cleanup_pending` | Last observed queued cleanup jobs, labeled only by `postgres` or `s3` backend. |
| `atoll_blob_cleanup_oldest_time_seconds` | Last observed oldest queued job timestamp per backend; 0 for empty/unobserved. |

Worker names cover identity refresh, blob cleanup, account cleanup, signup cleanup,
signup retry, OAuth key checks, event retention, and relay announcement. Results
use a fixed allowlist; unrecognized values become `other`. Workers disabled at startup retain
zero-valued series. Labels never contain account IDs, handles, request paths,
query text, credentials, or external URLs. Collection is always active in memory;
the setting controls HTTP exposure. Scrapes read counters, VM state, worker
configuration and local process registration without messaging workers, querying
PostgreSQL or contacting blob storage.

Firehose capacity is sampled every ten seconds when metrics are enabled. The
quota manager returns aggregate active/pending counts and configured limits in
constant time; the caller allows at most 100 ms. Scrapes only read the collector's
cached result. A failed snapshot marks inventory unavailable while retaining the
last successful values and timestamp. Collector restart resets observations;
quota-manager restart closes its tracked sockets and starts with empty counts.
There are nine fixed firehose series and no IP, DID, client ID or lease labels.
Admission counters count reservations, including ones whose subsequent handshake
fails; they are not counts of successfully established streams. Per-IP saturation
can therefore produce `full` outcomes while node-wide usage remains low. The
sampled counts can miss short-lived connections between polls.

The bundled alerts warn after node occupancy (active plus pending) exceeds 80%
for five minutes, or inventory failure/staleness lasts two minutes. Capacity
alerts require a fresh successful snapshot and a successful scrape. See the
[monitoring runbook](../ops/prometheus/README.md) for interpretation and recovery.

When metrics are enabled, the existing telemetry poller samples the durable blob
cleanup queue every ten seconds. Set
`config :atoll, :metrics_database_polling_enabled, false` to disable database
inventory separately; it is disabled by default in tests. Polls query only the
local database, using a 100 ms lock timeout, two-second statement timeout and
three-second transaction/client timeout. They never contact S3, delete jobs, or
acquire the repository write lock. Exact counts scan the queue, so very large
queues or pool contention can prevent an observation within those bounds.

Successful observations replace both backend counts and oldest timestamps.
Failures set availability to zero and preserve the previous snapshot and success
time. Always gate queue dashboards on availability and freshness; initial zeroes
are not proof of an empty queue. Cached observations reset with the collector.
The seven fixed series contain no CIDs or account identifiers. Every node polls
the shared queue independently: use per-instance views or a maximum across
replicas, not a sum that double-counts the same jobs. Pending jobs can include
objects retained for other owners or remote objects already deleted before a
local retry; the count is not reclaimable byte usage. Unexpired staged uploads
and other maintenance backlogs are not included.

`AtollDatabaseInventoryUnavailable` alerts after two minutes of failed polling
or stale observations (older than two minutes) while enabled and scrapeable.
`AtollBlobCleanupBacklog` alerts per backend when a fresh snapshot has jobs older
than 24 hours for five minutes, including when automatic cleanup is disabled.
Tune this threshold to your intended manual or scheduled cleanup policy. Keep
PDS and Prometheus clocks synchronized.

Each worker updates its progress deadline when scheduling its next tick, using
the actual delay plus its task timeout, rounded up to seconds. Idle rescheduling
also updates the deadline, so an empty queue is not treated as a stalled worker.
The `AtollWorkerProgressOverdue` alert fires when an observed deadline stays
overdue for two minutes while the target remains scrapeable. It clears when the
worker reschedules. Synchronize PDS and Prometheus clocks: these gauges use wall
time. A collector restart resets deadlines to zero until the next scheduling
event. `AtollWorkerMissing` detects configured workers with no registered process
for two minutes while scraping succeeds, even without prior scheduling events.
It reads the same enable flags/defaults as supervision, including the nested
signup and OAuth worker settings. Configuration changes alone do not start or
stop worker processes. Presence is not responsiveness: a registered worker that
is already stuck when the collector resets still needs separate health monitoring
until another progress event is observed. Intentionally stopping a worker
after it has been observed leaves its deadline in place until restart or another
scheduling event; account for planned maintenance in alert routing/silences.

Counters are local to each node and reset when the collector restarts. Scrape each
node separately and use Prometheus `rate()` or `increase()` before aggregating
counters across nodes. Individual counters are concurrent; a scrape is not an
atomic snapshot across all families. Endpoint counts include completed scrapes
and probes, and omit requests that terminate without an endpoint stop event.
Latency histograms expose cumulative `_bucket{le="…"}`, `_sum`, and `_count`
series. Fixed upper bounds in seconds are 0.001, 0.005, 0.01, 0.025, 0.05, 0.1,
0.25, 0.5, 1, 2.5, 5, 10 and +Inf: 45 additional series across three families.
Zero durations count as observations; missing, negative or noninteger timings do
not. Event counters still count those events, so they may differ from histogram
counts. Durations are bucketed at native clock precision; sums retain the existing
microsecond precision. Existing duration totals remain available. Each histogram's
+Inf bucket equals its count within a scrape; its sum is read independently.
Histograms reset with the collector. The runbook includes a percentile query and
its accuracy limits.

This exporter does not install Prometheus, configure alert delivery, or monitor disk capacity,
other backlogs, external services, or backup freshness. Baseline scrape, server-error,
readiness, database pool/total latency, worker-failure, missing-worker and overdue-progress alerts are available in
[`ops/prometheus/alerts.yml`](../ops/prometheus/alerts.yml), with setup instructions,
limitations and first-response checks in the
[operator runbook](../ops/prometheus/README.md). Validate them with
`bash scripts/test_monitoring.sh`; CI runs the same `promtool` checks and synthetic
rule tests, plus validation of the actual emitted metric format. Comprehensive monitoring and alerting remain on the checklist.

### Repository block cleanup

`mix atoll.blocks.prune --limit 500 --grace-seconds 86400` deletes one batch of old
DAG-CBOR blocks not referenced by retained revision inventories, revision commit
heads, current heads, or indexed records. The default grace is 24 hours; accepted
values are one hour through one year, with batch sizes 1–1000. Existing blocks
receive the migration time as their initial age. New blocks track first insertion;
repeated inserts preserve that timestamp.

Cleanup uses the same transaction advisory lock as repository writes, imports,
and account deletion, so selection and deletion cannot race new ownership. A
GIN index accelerates revision-inventory membership checks. Row locks skip locked
candidates; lock waits are limited to one second and SQL statements to five seconds.
Timeouts roll back the batch. Run again or schedule recurring invocations to clear
a backlog. No automatic block-cleanup scheduler is enabled.
Each successful batch, including a no-op, atomically records an
`atoll.blocks.prune` operator audit entry with the requested limit/grace, exact
cutoff, deleted count, and removed CIDs (at most 1000). It retains no block contents.
Audit insertion failure rolls back block deletion. Inspect these server-wide
entries with `mix atoll.moderation.history` without a DID filter.

Historical revisions remain owners even after a record is updated/deleted or an
account is deactivated. Account deletion removes those ownership inventories,
allowing unique blocks to expire while other accounts protect shared blocks.
Raw blob bytes are deliberately handled by the separate blob cleanup queue.
Standalone internal `Storage.put_node` writes have no ownership until attached to
a repository; callers must not rely on unowned blocks surviving beyond the grace
period. Operator revision compaction can release old ownership; normalized
reference counts track the remaining revisions.


### Repository storage quotas

Set `ATOLL_REPO_MAX_ACCOUNT_BYTES` (default 1073741824, 1 GiB) and
`ATOLL_REPO_MAX_ACCOUNT_BLOCKS` (default 1000000) before startup. Both require
nonnegative integers. These are separate from blob quotas. Each account is charged
once for each distinct stored CID referenced by any of its retained revisions,
including commit, MST, and record blocks. A block shared by accounts counts toward
each account's limit, even though its physical bytes are deduplicated.

Repository creation, record mutations, and CAR imports enforce both limits inside
their transaction. Failures return `RepoQuotaExceeded` and roll back all changes,
including new blocks, reference withdrawals, cleanup jobs, and events. Identical
CAR retries and empty HTTP write batches create no revision and remain allowed
after limits are lowered. Limits do not retroactively remove existing data.

Retained history consumes quota: deleting or replacing records does not release
its old blocks and creates a new commit. At the limit, even record deletions can
be rejected; compact eligible history or raise the limit. Unowned blocks and raw blob bytes do not count toward repository quota.
Usage scans the normalized distinct-CID reference index and stored block sizes;
constant-time byte accounting remains future performance work. Internal inventory is available through
`Atoll.Repositories.Quota.usage/1`.


### Authentication-state cleanup

Set `ATOLL_ACCOUNT_CLEANUP_ENABLED=true` before starting Atoll to enable the
supervised account cleanup worker. It is disabled by default and automatically
disabled in tests. Invalid values fail startup; application configuration uses
`config :atoll, :account_cleanup_enabled, true`.

The first batch starts after one minute. Each run deletes at most 500 expired
sessions and then at most 500 expired service-token replay markers, oldest expiry
first, with `FOR UPDATE SKIP LOCKED`. Live sessions and unexpired replay markers
are retained. Each prune transaction has a one-second lock timeout and five-second
statement timeout; the supervised task has a 15-second overall deadline.

The worker waits one minute after each completion or failure before trying again.
Runs do not overlap within an instance; locked or unfinished work remains eligible
for a later batch. Sessions and replay markers commit in separate transactions, so
a later failure does not undo earlier cleanup. Task crashes and timeouts do not
stop future scheduling. Worker shutdown terminates any active cleanup task.

Multiple nodes may run the worker: row locks prevent concurrent deletion of the
same batch. One enabled instance is usually sufficient; there is no cluster-wide
leader election or combined cluster batch limit. Cleanup does not acquire repository
locks, change passwords, or revoke live authentication.

The `[:atoll, :accounts, :cleanup]` telemetry event reports `runs: 1` and a `result`
of `ok`, `failed`, or `timeout`. Successful runs also report `sessions` and
`replay_markers` deletion counts. Failed runs do not claim counts for any partially
completed work. Telemetry contains no DIDs, credentials, or nonce digests.

### General XRPC request budget

`ATOLL_XRPC_RATE_LIMIT` sets the maximum number of XRPC requests per direct peer IP
per five-minute window on each node (default 3000, range 1–100000). Malformed or
out-of-range environment values fail startup. Application configuration uses
`config :atoll, :xrpc_rate_limit, 3000`.

The budget applies before routing validation, query/body parsing, authentication,
and WebSocket upgrade. All XRPC paths and methods share it, including unknown
methods, malformed paths, encoded route spellings, errors, and CORS preflights.
The explicit exception is local POST record procedures when `ATOLL_RECORD_WRITE_RATE_LIMIT=0`;
those writes bypass this budget as well as their specialized bucket. Requests
using `Atproto-Proxy` retain this aggregate budget even for record-write methods.
Existing login, write, blob, identity-resolution, and administrator limits still
apply independently and may reject requests sooner. An admitted subscription
handshake consumes one request; individual WebSocket frames do not consume this
HTTP budget. Subscription connection quotas remain separate future work.

Exhaustion returns HTTP 429 `RateLimitExceeded` with `Retry-After`, no-store, and
the standard public CORS headers. `[:atoll, :xrpc, :rate_limit]` telemetry reports
`count: 1` without identifying the client. `/health`, `/health/ready`, `/`, and
well-known identity routes are outside the XRPC budget.

Buckets use the existing bounded in-memory limiter and reset on process restart.
Limits are per node, not shared across a cluster. Forwarded headers are ignored by
default; explicitly configured trusted proxies can supply the client address as
described below. Select the PostgreSQL backend for shared limits across nodes.

### Trusted reverse proxies

By default, every request limit uses the directly connected peer address. To run
behind a reverse proxy, set `ATOLL_TRUSTED_PROXY_CIDRS` to that proxy's exact address
or network, for example `127.0.0.1/32,::1/128`. Values are comma-separated IPv4/IPv6
addresses or CIDRs, with at most 128 entries and 8192 bytes. Invalid configuration
fails startup. Use only networks whose proxies you control; a proxy in this list
is trusted to append or replace `X-Forwarded-For` correctly.

Atoll reads `X-Forwarded-For` only when the directly connected peer is trusted. It
walks the chain from right to left, skipping trusted proxy hops and stopping at the
first untrusted address. Entries farther left cannot override that boundary. If
all hops are trusted, the leftmost address is selected. The resolved address feeds
every existing request limiter, including login, identity, upload, writes, imports,
and administration. The original peer remains in `conn.private.atoll_peer_ip`.

Only one header field is accepted, with at most 2048 bytes and 32 literal IPs.
Missing, duplicate, malformed, or oversized headers fall back to the direct peer.
Hostnames, ports, brackets, zone identifiers, and `unknown` values are rejected.
IPv4-mapped IPv6 addresses normalize to IPv4 to keep trust checks and rate-limit
buckets consistent. A mapped IPv6 CIDR must have a prefix of at least 96 bits;
ordinary IPv4 CIDRs also match mapped IPv4 peers.

`Forwarded`, `X-Real-IP`, and `CF-Connecting-IP` are not used for client addressing.
This setting does not change request host, port, or scheme and does not enable
distributed rate limiting. Without configured trust, clients behind a proxy share
that proxy's budget. Application configuration can use
`config :atoll, :trusted_proxies, AtollWeb.ClientIP.parse_trusted_proxies!("127.0.0.1/32")`.

### Shared request limits across nodes

Set `ATOLL_RATE_LIMIT_BACKEND=postgres` to use PostgreSQL for every HTTP request
budget: general XRPC, login/session, identity resolution, record writes, uploads,
imports, and administration. All nodes must use the same database, backend, limit
settings, and trusted-proxy policy. The default is `memory`, retaining the existing
node-local limiter. Invalid backend names fail startup. Application configuration
uses `config :atoll, :rate_limit_backend, :postgres`.

Apply migration `20260926142505` before enabling the PostgreSQL backend. It stores
a SHA-256 digest of each internal bucket key, its count, and expiry; raw addresses,
credentials, and request bodies are not stored in the bucket table. Digests are
not intended to anonymize guessable IP addresses. Five-minute windows begin with
the first admitted request and use the database clock. Denied requests do not
extend expiry. Counts survive application/node restarts. Switching backends does
not migrate counters and can grant a fresh budget.

A dedicated transaction advisory lock serializes admission and storage-cap checks
across nodes. It is separate from repository/event locking. Storage is capped at
10,000 buckets across all kinds and nodes. A new bucket reclaims at most 1000
expired rows before checking the cap; idle expired rows may remain until another
new bucket is admitted. At capacity, new keys are denied for up to five minutes
while existing keys retain their remaining budget.

Database lock waits are limited to one second and statements to two seconds.
Database errors deny the request through the existing 429 response with a
one-second `Retry-After`; they never silently switch to independent memory limits.
`[:atoll, :rate_limit, :unavailable]` reports `count: 1` without request details.
Health and other non-XRPC routes remain outside the general request budget.

This backend favors consistent, bounded admission over maximum throughput: each
budget check requires a database transaction and shares the admission lock. Load
test it for the expected request volume. It does not provide sliding windows,
or per-account abuse policy. A separate optional Redis backend is described below. HTTP guards consume budgets before
handler transactions, so a failed handler does not restore its request allowance.

### Requesting relay crawls

Set `ATOLL_RELAY_URLS` to a comma-separated list of up to ten relay HTTPS origins,
then run `mix atoll.relays.request_crawl` in the intended environment. For example,
use the relay origins agreed with your relay operators. Merely configuring this
setting does not send anything; the command explicitly makes network requests.
Application configuration uses `config :atoll, :relay_urls, ["https://relay.example.com"]`.

The command derives the advertised hostname from Atoll's configured public endpoint
URL (`PHX_HOST` in production). That URL must use HTTPS on port 443 with a
non-reserved DNS hostname. Relay origins have the same HTTPS/port requirement and
cannot include credentials, query strings, fragments, or non-root paths. Duplicate
normalized origins are contacted once. No relays are configured by default.

Each relay receives an unauthenticated POST to
[`com.atproto.sync.requestCrawl`](https://github.com/bluesky-social/atproto/blob/main/lexicons/com/atproto/sync/requestCrawl.json)
with only `{ "hostname": "your.pds.host" }`. No account token, admin credential, or
email secret is sent. Relay destinations are trusted operator configuration, never
user-provided request URLs. These are outbound announcements; Atoll does not expose
an incoming relay crawl endpoint.

Requests run sequentially with three-second connection and five-second request
timeouts, a 4 KiB response-body limit, and no redirects or automatic retries. One
relay's rejection does not prevent the remaining configured relays from receiving
a request. JSON output reports `accepted`, `host_banned`, `unavailable`, or
`rejected` per relay without copying upstream messages. The command exits with an
error if any relay does not accept the request. Outcome telemetry uses
`[:atoll, :relay, :crawl]` with a count and outcome only.

The operator command uses `Atoll.Relays.request_crawl_audited/1` to record a
server-wide `atoll.relays.requestCrawl` audit attempt before sending. The record
contains the normalized PDS hostname and configured relay origins. A separate
completion links to the attempt ID and stores only the bounded per-relay outcome
labels, without response bodies or credentials. Read these entries through
`mix atoll.moderation.history` without a DID filter. Invalid configuration creates
no attempt, and failure to persist the attempt prevents network requests.

Network calls run outside the audit transactions. A crash, interruption or failure
to record completion can leave an attempt without completion even if requests
reached relays; this means the outcome is unknown. The CLI distinguishes a failed
attempt record from failed outcome recording and does not retry automatically.
The audited API refuses calls inside an existing database transaction so the
attempt can commit before sending. Periodic announcements continue using their
existing outcome telemetry rather than creating recurring operator audit entries.

Acceptance means the relay accepted the request; it does not prove that it has
connected, indexed repositories, or satisfied its hosting policies. Crawling requires
the public PDS routes and subscription stream to be reachable. Relay discovery and
live federation interoperability checks remain pending. Tests use mocked relay responses and never announce the development PDS.


### Periodic relay announcements

To announce automatically to the configured `ATOLL_RELAY_URLS`, set:

```sh
export ATOLL_RELAY_CRAWL_ENABLED=true
export ATOLL_RELAY_CRAWL_INTERVAL_SECONDS=900
```

Scheduling is disabled by default and always disabled in the test environment.
Enabling it requires at least one configured relay. The interval must be between
300 and 86400 seconds. Application settings are `:relay_crawl_enabled` and
`:relay_crawl_interval_seconds`. The public endpoint requirements above still apply.

The supervised worker starts its first batch after one minute, then waits the
configured interval after each batch finishes. Each pass contacts every configured
relay, including relays that previously rejected or failed a request. Batches do
not overlap and have a 60-second deadline; a timeout kills the task. Failures,
crashes, and timeouts schedule another pass. Requests retain the per-relay limits
above; there are no immediate retries.

`[:atoll, :relay, :announcement]` telemetry reports `runs: 1` and a result of
`completed`, `failed`, or `timeout`. Completed batches include counts for
`accepted`, `host_banned`, `unavailable`, and `rejected`; completion does not mean
all relays accepted the announcement. Interrupted batches do not report partial
counts. Per-relay outcome telemetry remains available.

Scheduling is per process, without a database lease or leader election. Enable it
on one instance of a multi-node PDS to avoid duplicate periodic announcements.
Tests mock all outbound requests; enabling this setting in a running deployment
makes real network requests.


### Distributed automatic identity refresh

Migration `20260926145956` adds one lease row per visited repository, removed by
account deletion. Automatic sweeper tasks atomically claim a DID for 60 seconds
using PostgreSQL time and a random ownership token. Competing nodes skip leased
DIDs without resolving them. Completed attempts, including resolution failures,
set a shared five-minute cooldown. Leases and cooldowns survive node restarts;
there is no separate leader or shared in-memory state.

The worker's 20-second task deadline remains shorter than the lease. A timeout,
crash, or shutdown leaves the lease to expire, allowing a later sweep to reclaim
it. Before publishing an observation or identity event, the refresh transaction
locks the lease row and checks the token and expiry after acquiring that lock.
An expired or replaced task cannot publish, and an old completion cannot release
a newer lease. Network resolution runs outside these database transactions.
Coordination queries have one-second lock and five-second statement limits;
a claim failure does not fall back to uncoordinated network work.

Each node still scans its own DID cursor with one-second spacing and a five-minute
pause between sweeps. This coordinates duplicate work; it does not distribute a
central job queue or guarantee a five-minute refresh SLA for large repository
lists. Owner-requested `refreshIdentity` and direct internal refresh calls remain
independent of automatic leases and retain their existing authorization and
observation concurrency checks. The leases fence automatic observation/event
publication, not resolver cache fills. Tests include simultaneous claims through
independent database connections and stale-worker publication rejection.


### S3 object inventory

With S3 blob storage configured, inspect one read-only page using:

```sh
mix atoll.blobs.inventory --limit 100
mix atoll.blobs.inventory --limit 100 --cursor 'TOKEN_FROM_PREVIOUS_PAGE'
```

The command uses the existing S3 endpoint, bucket, region, and signing credentials.
It requires bucket listing permission (`s3:ListBucket` on AWS) in addition to any
object permissions used by normal uploads. It sends signed
[ListObjectsV2](https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html)
requests restricted to `blobs/`, requesting URL-encoded keys. Limits are 1–1000
objects per page, default 100. Continue using the returned opaque `cursor` until
it is absent, even if a page is empty. The command makes one request per invocation
and does not follow redirects or retry automatically.

JSON output includes `objects` and per-status `counts`. Each object includes its
key, listed byte size, last-modified timestamp, and one of these statuses:

- `owned`: at least one account has S3 ownership metadata for this raw CID.
- `pending_cleanup`: no S3 owner exists, but an S3 cleanup job is queued.
- `untracked`: a canonical raw-CID object has neither S3 ownership nor a cleanup job.
- `unrecognized_key`: the key is not Atoll's canonical `blobs/<raw CID>` format.

Ownership takes precedence over a queued cleanup job, including shared blobs.
PostgreSQL ownership of the same CID does not establish ownership of an S3 object.
All metadata classifications within a page use one database query snapshot.
Objects marked `untracked` may result from a failed upload transaction, but may
also be uploads that have reached S3 and have not committed their metadata yet.
The report is not deletion authorization. It never deletes objects, queues cleanup,
changes ownership, or downloads object contents.

A listing response is bounded to 5 MiB and parsed using OTP's SAX XML parser without
dynamic atoms, DTDs, or external entities. Parsing also bounds nesting, node count,
and text fields, validates sizes/timestamps/keys, and rejects duplicate keys and
inconsistent pagination metadata. Database reads use one-second lock and five-second
statement limits; listing requests use the existing S3 connection/request limits.
Errors do not copy provider responses or credentials into command output.

Inventory covers current objects under `blobs/` in the configured bucket. It does
not inventory previous object versions, multipart uploads, other prefixes, or raw
PostgreSQL blocks, and it does not verify bytes against CIDs or detect missing
objects absent from the listing. Concurrent bucket and database changes mean a
multi-page scan is not a global snapshot. Automated deletion of untracked objects
remains unimplemented. Tests include real signed pagination and classification
against disposable loopback MinIO, with confirmation that inventory preserves bytes
and queued cleanup jobs.


### Event retention and expired replay cursors

Event history remains retained by default unless automatic retention is enabled.
To explicitly prune one bounded batch:

```sh
mix atoll.events.prune --limit 1000 --retention-seconds 604800
```

The default retention is seven days; supported values range from one hour to one
year. Batch limits are 1–1000. The command deletes only an expired prefix in sequence
order and stops at the first newer event, even if later events have older timestamps.
It uses the database clock. Repeat the command to clear an expired backlog; automatic scheduling is also available as described below. JSON output includes
`deleted` and a string `cursorFloor`, preserving the full integer value.

Deletion and the replay boundary commit in one transaction under the existing event
sequencing lock, with one-second lock and five-second statement deadlines. Migration
`20260926152208` stores the highest pruned sequence independently of remaining event
rows. Pruning every event therefore preserves the stream's last committed position.
Rollback preserves both events and the prior boundary. Retention does not delete
repository revisions, blocks, account records, or operator audit history.
Every successful operator batch, including a no-op, records an `atoll.events.prune`
audit entry in that transaction. Scheduled batches that delete events record the
same operation with actor `worker`; idle scheduled checks create no audit rows.
Entries contain the requested limit/retention, deletion count, and previous/new
cursor floors as lossless strings, without retaining event payloads or account
identifiers. Audit insertion failure rolls back deletion and the replay boundary.
View server-wide entries with `mix atoll.moderation.history` (without a DID filter).

An explicit positive cursor below that boundary receives the protocol's
`#info` / `OutdatedCursor` message before replay resumes above the boundary.
Consumers must treat the notice as evidence that requested history is missing and
resynchronize as their application requires. `cursor=0` explicitly requests the
oldest retained history without a stale-cursor notice; omitting the cursor starts
at the current position. Exact-boundary cursors remain valid, and future cursors
still fail. Subscribers overtaken by pruning while connected receive the same
notice before continuing. The existing 10000-event backlog limit still applies.

Replay holds a shared boundary-row lock through event selection, so pruning cannot
slip between the boundary check and selection and silently omit events. Retention
waits for those short read transactions. Sequence gaps alone do not establish an
expired cursor: the boundary moves only when the retention command deletes a prefix.
Preserve this table alongside events when backing up or restoring the database.
Tests cover bounded/non-monotonic timestamp pruning, atomic rollback, empty streams,
and real loopback WebSocket notice ordering. No existing development event history
was pruned while implementing this feature.


### Automatic event retention

To enable periodic pruning, configure both the opt-in switch and retention policy:

```sh
export ATOLL_EVENT_RETENTION_ENABLED=true
export ATOLL_EVENT_RETENTION_SECONDS=604800
```

Scheduling defaults to disabled. Retention defaults to seven days and must be
between 3600 and 31536000 seconds, including when scheduling is disabled. Invalid
settings fail startup. Application configuration uses `:event_retention_enabled`
and `:event_retention_seconds`. The runtime disables the scheduler in tests.

The supervised worker waits one minute before its first run, prunes at most 1000
expired events, then waits one minute after completion before the next batch.
It uses the same atomic prefix deletion and durable replay boundary as the operator
command. It does not loop immediately through a backlog or prune repository blocks.
Consumers overtaken by retention receive the existing `OutdatedCursor` notice.

Each batch runs in a supervised task with a 15-second deadline. Failed, crashed,
or timed-out tasks allow a later batch; active batches do not overlap within a
worker. Shutdown terminates the active task. PostgreSQL transactions protect the
boundary and deletion together, including rollback if a task is killed before
commit. A task killed after commit but before reporting may have completed work;
subsequent batches safely continue from the persisted boundary.

`[:atoll, :events, :retention]` telemetry reports `runs: 1` with result `completed`,
`failed`, or `timeout`. Completed runs additionally report `deleted` and `floor`.
Failure and timeout measurements do not claim a deletion count. Database locking
serializes concurrent pruning across instances, without leader election. Configure
the same retention policy on every node; a shorter policy on any enabled node can
prune history earlier. Aggregate pruning throughput grows with enabled instances.
No retention worker was enabled against development data during implementation.


### Retained block reference index

Migration `20260926152913` adds `repository_block_refs`, with one row per distinct
repository/CID pair and a count of retained revisions referencing that CID. It
backfills from existing revision block arrays and installs a PostgreSQL trigger
that updates counts on revision insertion, replacement, and deletion. Duplicate
CIDs in one revision count once. Index changes commit or roll back with the revision,
and deleting an account removes its reference rows without affecting other owners.

Quota and account-status block inventories now use this index instead of expanding
all retained revision arrays on each read. Garbage collection uses the global CID
index to test retained ownership, while preserving the existing independent checks
for current heads, revision commits, and current records. Quota byte accounting
still reads the sizes of distinct stored blocks; it is not a constant-time counter.

Revision arrays remain available for export and signed-tree membership verification.
The derived index does not authorize public block access and does not replace
cryptographic proof checks. No revisions are compacted or blocks deleted by this
migration. Revision compaction preserves revisions needed by retained stream
events before removing revision ownership.

The migration locks revision writes while backfilling and installing the trigger;
large histories require a planned migration window. Back up and restore the index
and trigger together with revision tables. Application code must not mutate the
index directly or disable its trigger. Downgrading drops the derived index and
trigger while retaining the authoritative revision arrays. This improves ownership
lookups and inventory scaling; full-history arrays and rebuilding the complete MST
on writes remain scalability limitations.


### Revision-history compaction

Run an explicit bounded batch for one repository:

```sh
mix atoll.revisions.prune did:plc:YOUR_DID --limit 100 --retention-seconds 604800
```

This irreversibly removes up to 100 eligible historical revision inventories.
Retention defaults to seven days and accepts one hour through one year. The current
head is always preserved. Retained commit events pin both their commit revision
and predecessor revision; sync events pin their commit revision. Event retention
must release these pins before compaction can reclaim that history. No automatic
revision-compaction scheduler is enabled.

The command prints `pruned`, `indexed`, and `incomplete`. For rolling upgrades,
it first indexes up to 1000 events missing dependencies. If indexing is incomplete,
it commits only that indexing work and removes no revisions; repeat the command.
Events and their dependency rows are immutable application data; do not edit or
partially remove dependency rows manually. Deleting an event cascades its pins.

Migration `20260926153249` backfills event dependencies while blocking event writes;
plan a migration window for large histories. Existing revisions receive the migration
time as their conservative age baseline. New revisions record their insertion time.
Compaction holds the repository head lock and global event mutation lock, with
one-second lock and five-second SQL statement timeouts. Failed batches roll back.
Every successful batch, including no-op and dependency-backfill-only batches,
records an `atoll.revisions.prune` operator audit entry in that same transaction.
It includes the requested limit and retention, preserved head/revision, removed
revision identifiers (at most 100), and indexing/pruning results; no record bodies
or keys are retained. Audit insertion failure rolls back pruning and indexing.
Inspect these entries with `mix atoll.moderation.history --did DID`.

Reference counts and quota usage update transactionally. Physical block deletion
is a separate `atoll.blocks.prune` operation after its own grace period; shared
owners remain protected. Historical reads lose access through compacted revisions,
and exports with a compacted `since` revision fall back to a full current snapshot.
Current exports and retained replay frames remain valid. Back up dependency rows
alongside events and revisions. This does not reduce the full-tree rebuild cost of
writes or eliminate complete block arrays for retained revisions.


### Optional Redis

Atoll requires no Redis by default: request budgets remain in memory. For shared
budgets across multiple instances, choose Redis explicitly:

```sh
export ATOLL_RATE_LIMIT_BACKEND=redis
export ATOLL_REDIS_URL='redis://127.0.0.1:6379/0'
export ATOLL_REDIS_NAMESPACE=atoll
```

Use `rediss://` for TLS; URLs may include Redis username/password credentials and
a database number. Redix verifies TLS certificates and hostnames using the system
CA store. Keep credentials in your secret configuration. All instances sharing a
budget must use the same Redis database and namespace. The namespace defaults to
`atoll` and accepts 1–64 letters, digits, underscores, or hyphens. `memory` remains
the default backend; the existing `postgres` backend is still available. Redis is
not connected unless selected. Identity caches remain bounded node-local memory;
PostgreSQL remains authoritative for accounts, sessions, and repositories.

A single Lua script atomically admits requests using Redis server time, fixed
five-minute windows, and SHA-256 digests of the existing request-budget keys.
Two keys sharing a Redis hash tag hold counts and expiry times. Storage is capped
at 10,000 buckets per namespace, expired entries are reclaimed in bounded batches,
and idle limiter state expires after five minutes. Configure Redis with a
`noeviction` memory policy: eviction or clearing its state resets budgets. Redis
outages, command timeouts, or inconsistent state fail closed with a short retry
interval; there is no automatic fallback that would grant new local budgets.
The client reconnects automatically. Redis replication/failover can lose recent
budget updates; this is operational rate limiting, not durable account state.

Real Redis tests are opt-in, using an isolated test instance/database:

```sh
ATOLL_TEST_REDIS_URL=redis://127.0.0.1:6379/0 \
  mix test test/atoll/redis_limiter_test.exs --include redis
```

Tests use unique namespaces and delete their own keys on completion. Normal
`mix precommit` requires neither Redis nor Docker.

### Default moderation service routing

`ATOLL_MOD_SERVICE_PROXY` and `ATOLL_REPORT_SERVICE_PROXY` name `DID#service`
references validated at startup, like `ATOLL_APPVIEW_PROXY`. When configured,
authenticated requests without an `Atproto-Proxy` header are forwarded:
`com.atproto.moderation.createReport` goes to the report service (falling back
to the moderation service when no separate report service is set), and every
`tools.ozone.*` method goes to the moderation service, mirroring the
[upstream default-service table](https://github.com/bluesky-social/atproto/blob/7a857989751ae31518509d69ab7194a922064f3d/packages/pds/src/pipethrough.ts).
Atoll routes the whole `tools.ozone.*` prefix rather than the upstream method
enumeration, so new ozone methods reach the same operator-chosen service.

These defaults use the existing authenticated proxy path: an active session or
an OAuth grant with a matching `rpc:` permission, fresh service resolution,
short-lived account-signed service tokens, the shared body/response bounds, and
the protected account-management method refusals. An explicit `Atproto-Proxy`
header still overrides the default destination, and unconfigured destinations
keep returning `501 MethodNotImplemented`.

### Structural media validation

`ATOLL_MEDIA_VALIDATION=images` enables bounded structural checks for image
uploads; the default (`off`) matches the reference PDS, which stores bytes
verbatim. When enabled, blobs detected as PNG, JPEG, GIF, WebP, or BMP must
parse structurally — signature, header shape, chunk/segment walk to the
required trailer — and their declared dimensions must not exceed
`ATOLL_MEDIA_MAX_PIXELS` (default 268,435,456). A declared MIME type among
these formats must also match the detected signature, so mislabeled uploads
fail with `400 InvalidMedia` before any bytes are stored.

Parsing reads container structure only: no pixel decoding, decompression, or
byte transformation occurs, adversarial marker-stuffing runs in linear time
inside the existing 5 MiB body bound, and formats outside the supported set
(other images, audio, video, documents) continue to be stored verbatim. This
is not a malware scanner. Both settings are also available per call site
through the internal staging options for tests and embedding.

### Production deployment

Atoll boots in production only with `DATABASE_URL`, `SECRET_KEY_BASE`,
`PHX_HOST`, `ATOLL_PDS_DID`, `ATOLL_KEY_ENCRYPTION_KEY` and
`ATOLL_SESSION_SIGNING_KEY` present, so a misconfigured node refuses to start
instead of failing on first use. Generate each 32-byte secret with
`openssl rand -base64 32` (and `SECRET_KEY_BASE` with `mix phx.gen.secret`),
keep them out of version control, and back up the key-encryption key together
with the database: encrypted signing-key custody is unrecoverable without it.
`ATOLL_OAUTH_NONCE_SECRET` and `ATOLL_ADMIN_PASSWORD` unlock OAuth and the
operator endpoints; the rotation workflows for master keys, session keys and
PLC authority keys are described in [keys.md](keys.md).

Build a release with `MIX_ENV=prod mix release` and run migrations with
`bin/atoll eval "Atoll.Release.migrate()"` (or `mix ecto.migrate` on a
source deploy). The server listens on plain HTTP
(`PORT`, default 4000) and expects a TLS-terminating reverse proxy for the
public origin. The proxy must forward WebSocket upgrades for
`/xrpc/com.atproto.sync.subscribeRepos` and preserve `X-Forwarded-For`; list
the proxy in `ATOLL_TRUSTED_PROXY_CIDRS` so rate limits see client addresses.
A minimal Caddyfile:

    pds.example.com, *.users.example.com {
      reverse_proxy 127.0.0.1:4000
    }

Wildcard user-domain hosts need DNS and certificates at the proxy (Caddy's
on-demand TLS or a wildcard certificate). Set `ATOLL_FORCE_SSL=true` to add
HSTS and redirect any plain-HTTP request that reaches Atoll itself, using the
proxy's `X-Forwarded-Proto`. Health endpoints for orchestration are
`GET /health` (liveness) and `GET /health/ready` (database readiness);
`GET /metrics` serves operator-authenticated Prometheus metrics with the alert
rules and runbook in `ops/prometheus`. Backup and recovery-set tooling lives in
`scripts/` with drills documented above and in `ops/backup`.

### Read-only maintenance mode

Start a node with `ATOLL_READ_ONLY=true` to hold it in maintenance: every POST
(XRPC, OAuth and browser forms) is refused before body parsing with
`503 ServiceUnavailable` and a `Retry-After` header, OAuth-credentialed reads
are refused too because DPoP proof admission persists replay state, and none of
the optional background writers (cleanup, retention, identity refresh, relay
announcements, signup retries, OAuth key checks) are started. Missing-worker
metrics expect zero workers in this mode, so maintenance does not page.

Public reads, password and app-password session reads, preference exports, the
firehose, `/.well-known` documents, health probes and operator metrics keep
working, so downstream consumers can drain while the database and S3 snapshot
are taken (see `ops/backup`). The switch is per node and read at boot; restart
nodes into and out of maintenance rather than reconfiguring a live system, and
quiesce every node that shares the database before calling a snapshot
consistent.

### Service health and legacy sync endpoints

`GET /xrpc/_health` reports the application version and probes the database
with the bounded readiness query, returning `{"version": ...}` or a 503 with
`error: "Service Unavailable"`, matching the reference PDS's route used by
relays and monitors. It bypasses proxy candidacy and request-rate admission,
answers only GET, and is never cached. `GET /robots.txt` explicitly allows
crawling the public API, as the reference server does.

The deprecated `com.atproto.sync.getHead` and `com.atproto.sync.getCheckout`
remain served for older consumers, as they are upstream. `getHead` returns the
current signed commit CID as `root` with the same availability rules as
`getLatestCommit`; `getCheckout` streams the same complete CAR snapshot as
`com.atproto.sync.getRepo`, ignoring any `since` parameter, and shares
`getRepo`'s owner-token and operator export authorization for inactive
accounts. New consumers should use `getLatestCommit` and `getRepo`.

### Feed generator proxying and service-token audiences

Proxied requests follow the upstream phase-1 service-auth model: permission
checks (OAuth `rpc:` grants and consent) see the combined `did#service`
audience, while the outbound account-signed JWT carries the bare DID that
AppViews, chat services and feed generators actually verify today. Tokens
requested explicitly through `com.atproto.server.getServiceAuth` keep exactly
the audience the caller asked for.

`app.bsky.feed.getFeed` gets the reference implementation's special handling:
after caller authorization, Atoll fetches the feed's published generator
record from the destination service without credentials, requires a valid
`did` in it, and signs the forwarded request with `aud` set to that generator
and `lxm` of `app.bsky.feed.getFeedSkeleton`, so generators accept skeletons
requested through the AppView. OAuth callers need RPC grants for both
`getFeed` and `getFeedSkeleton` at the destination, exactly as upstream
asserts. Missing, malformed, or unresolvable feed references return
`400 UnknownFeed` after authorization, and the feed lookup happens only for
admitted callers.

Proxied AppView reads apply the reference server's read-after-write munging.
When the response's `atproto-repo-rev` trails recent local commits, Atoll
splices the requester's own not-yet-indexed writes into `getTimeline`,
`getAuthorFeed` (own feeds only), `getPostThread`, `getProfile`, `getProfiles`
and `getActorLikes`: fresh posts appear with zero counts and locally formatted
image/external embeds, record embeds render as not-yet-found exactly like the
reference viewer without an AppView back-channel, profile edits overlay
display name, description, avatar and banner, and an entirely unindexed
thread the requester wrote is served from local records. Munged responses
carry `atproto-upstream-lag`; any parse or munge failure returns the upstream
body untouched. Local reads are bounded to the newest thirty commits and ten
records, and a revision at or before the AppView's clock must exist locally so
migrated repositories are never munged against a foreign clock. Image URLs use
`ATOLL_IMAGE_CDN_URL_PATTERN` (an HTTPS pattern with three `%s` slots for
preset, DID and CID) or fall back to this server's public `getBlob` route.

`app.bsky.notification.registerPush` and `unregisterPush` follow the same
upstream model: the service is named by the request body's `serviceDid`, so
OAuth grant assertion is deferred to token issuance with audience
`serviceDid#bsky_notif`, the signed token carries the bare service DID, and
the request is delivered to the default AppView when it is that service or
directly to the named service's resolved `#bsky_notif` endpoint otherwise. An
explicit `Atproto-Proxy` header keeps its ordinary generic behavior on these
routes.
