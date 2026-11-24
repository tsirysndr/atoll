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
| Blob references | Skip reference deletion and withdrawal queries when no prior references exist. Blob-bearing records retain validation and ownership checks. |
| Transaction setup | Set both local PostgreSQL timeout parameters in one parameterized query. Existing limits remain enforced. |
| Session cleanup | Empty scheduled batches avoid the global event lock. Expected lock contention returns a busy result for later retry instead of crashing the worker task. Manual audit and rollback behavior remain. |
| Ordered record queries | Add `(did, path COLLATE "C") INCLUDE (cid)` to match bytewise ordering and allow index-only lookup. |
| Block deletion / ownership checks | Add referencing-side indexes on record CID, repository head and revision head. PostgreSQL does not automatically index foreign-key referencing columns. |
| OAuth and replay admission | Existing primary-key/digest, expiry and session indexes cover the observed queries. Preserve atomic admission locks, bounded cleanup and authorization rechecks. |
| Identity and signup workers | Existing lease keys, retry partial indexes and bounded batches cover their predicates. Preserve lease and publication ordering. |
| Admin, invitations, preferences | Existing account, email, owner, usage and cursor indexes cover normal access; retain bounded pagination and consistent audit/authorization reads. |
| Metrics and readiness | Inventory is already bounded and outside the request path; liveness/readiness and query deadlines remain distinct. |

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
