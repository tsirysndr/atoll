# Database query audit — 2026-11-24

Reviewed SQL and Ecto query sites across repositories, storage, blobs, accounts,
OAuth, identity, moderation, metrics and readiness against production
`pg_stat_statements`, table sizes and index definitions. The initial source
inventory found 328 matching query/fragment sites; this is an inventory of call
sites, not 328 distinct execution plans.

## Production evidence

- Primary PostgreSQL is remote (US East); a `SELECT 1` round trip measured 287 ms.
- The reported account had 104 indexed records. Its ordered record lookup spent
  391 ms in execution, almost all in disk reads, and required a separate sort.
- Retention-floor share locks accounted for approximately 49 million calls
  across statistics entries. Idle subscribers opened transactions, checked
  backlog and locked the floor every 500 ms even when there was nothing to send.
- Global event locks averaged 392 ms and reached 14.9 seconds. Repository share
  locks also reached 14.9 seconds. These are lock-wait totals, not evidence that
  a primary-key lookup lacks an index.
- Atoll logs showed connection deadlines during COMMIT and session cleanup
  failing to acquire the shared event lock. The application host was also under
  high CPU load. Raising every timeout would not remove these causes.

## Changes

| Query family | Change or finding |
| --- | --- |
| Idle firehose polling | One unlocked bounds query when caught up; no empty transaction or retention-floor lock. Count backlog only when the sequence distance can exceed the cap. Real replay retains floor and availability locking. |
| Record mutation | Batch generated MST nodes by 128 nodes or 1 MiB, verify existing conflicting bytes in batches, and stop fetching every generated node again. Trees remain canonical, atomic and quota checked. |
| Record enumeration | Fetch at most 1025 metadata rows to use a single query for small repositories; larger repositories use bounded 1024-row streaming. |
| Revision membership | PostgreSQL constructs the deduplicated ordered membership array from generated node CIDs, current indexed record CIDs and commit CID in one statement. SQLite retains transactional staging. |
| Blob cleanup | Empty scheduled expiry batches avoid transactions and the global lock. Nonempty scheduled expiration and collection use a nonblocking lock attempt, returning `:cleanup_busy` for the next scheduled retry. Bounded expired ownership is deleted in one statement. Expected lock/statement contention does not crash the task, and pending jobs remain durable. |
| Blob references | Skip reference deletion and withdrawal queries when no prior references exist. Blob-bearing records retain validation and ownership checks. |
| Transaction setup | Set both local PostgreSQL timeout parameters in one parameterized query. Existing limits remain enforced. |
| Migration startup | Probe a cold pool without queuing until a connection is usable (bounded to 60 seconds), before submitting migration DDL. This prevents normal checkout shedding from aborting a deployment during TLS connection startup. |
| Session cleanup | Empty scheduled batches avoid the global event lock. Expected lock contention returns a busy result for later retry instead of crashing the worker task. Manual audit and rollback behavior remain. |
| Ordered record queries | Add `(did, path COLLATE "C") INCLUDE (cid)` to match bytewise ordering and allow index-only lookup. |
| Block deletion / ownership checks | Add referencing-side indexes on record CID, repository head and revision head. PostgreSQL does not automatically index foreign-key referencing columns. |
| OAuth and replay admission | Existing primary-key/digest, expiry and session indexes cover the observed queries. Preserve atomic admission locks, bounded cleanup and authorization rechecks. |
| Identity and signup workers | Existing lease keys, retry partial indexes and bounded batches cover their predicates. Preserve lease and publication ordering. |
| Admin, invitations, preferences | Existing account, email, owner, usage and cursor indexes cover normal access; retain bounded pagination and consistent audit/authorization reads. |
| Metrics and readiness | Inventory is already bounded and outside the request path. Readiness now permits five seconds for the remote pool instead of disconnecting healthy TLS connections at one second during startup; failed/unreachable probes still report unavailable. |

PostgreSQL indexes are created concurrently; a matching SQLite migration is
included. No stored records are changed by the migration.

## Verification and remaining limits

Regression coverage checks exact canonical roots and revision membership,
corruption rejection, quotas, rollback, event replay and the SQL query budget
for a populated repository. Idle-poll coverage checks that it runs exactly one
unlocked query.

Query count and lock pressure are reduced, but a remote database or network
outage can still fail a write. The database remains a synchronous dependency;
these changes do not promise zero timeouts under every failure condition.

Production verification: all four new indexes were valid and the migration
version was `20261124091601`. Three internal single-record writes against the
reported account, each inside an outer rolled-back transaction, took 4699,
4620 and 5589 ms with 17 SQL calls each. The account head was unchanged and
readiness returned `:ready`. These measure the mutation path without an HTTP
authorization round trip or a committed transaction; they are not end-to-end
client latency measurements. The full precommit run passed 1662 tests (23
excluded), and 64 targeted SQLite tests passed.

Follow-up production logs identified one-second readiness connection disconnects
at startup and an uncaught blob-expiration lock timeout. Regression tests now
cover a healthy pool held for more than a second, a contended nonblocking
maintenance lock, and empty scheduled blob expiration without lock acquisition.
