# Atoll
[![ci](https://github.com/tsirysndr/atoll/actions/workflows/test.yml/badge.svg)](https://github.com/tsirysndr/atoll/actions/workflows/test.yml)

An AT Protocol Personal Data Server (PDS), built with Elixir, Phoenix, and PostgreSQL. Work in progress.

Atoll currently provides server metadata, verified block storage, and internal APIs for signed repositories. Account hosting and federation are not implemented yet.

## Feature checklist

Checked items are implemented in this repository. Unchecked items are remaining work; this is a development roadmap, not a complete protocol conformance checklist.

### Server foundation

- [x] Phoenix API application with a PostgreSQL connection through Ecto.
- [x] Database migrations and isolated database tests.
- [x] `GET /health` HTTP liveness endpoint (does not check database readiness).
- [x] `GET /` plain-text ATProto ASCII banner and API location.
- [x] `GET /xrpc/com.atproto.server.describeServer` with configurable `did` and `availableUserDomains`.
- [x] Controller test for unauthenticated server description.
- [x] Validated runtime server DID and advertised domain configuration (development defaults to `did:web:localhost`).
- [x] Configured hostname-based server DID document publication with a stable service key.
- [ ] General XRPC request validation and protocol error responses.
- [ ] Lexicon-based record validation.

### Content identifiers and encoding

- [x] Unsigned varint encoding and decoding with a 63-bit limit and minimal-encoding validation.
- [x] CIDv1 construction for `raw` and `dag-cbor` codecs using SHA-256.
- [x] Strict binary CID parsing, including header and digest-length validation.
- [x] Canonical lowercase, unpadded base32 CID formatting and parsing.
- [x] Verification that content bytes match a CID's digest.
- [x] Known-value and malformed-input tests for varints and CIDs.
- [x] Deterministic CBOR encoding for signed 64-bit integers, booleans, and null.
- [x] CBOR UTF-8 text and byte-string encoding with minimal length headers.
- [x] CBOR array and map encoding with deterministic UTF-8 key ordering.
- [x] CBOR CID-link encoding using tag 42 and validated binary CIDs.
- [x] Strict CBOR scalar decoding with minimal-encoding, integer-range, and trailing-data checks.
- [x] Strict CBOR text and byte-string decoding with UTF-8 and length validation.
- [x] Strict CBOR array decoding with element validation and a nesting limit.
- [x] Strict CBOR map decoding with UTF-8 keys, canonical ordering, and duplicate rejection.
- [x] Strict CBOR CID-link decoding with tag, prefix, and CID validation.
- [x] Deterministic CBOR encoding and strict decoding for ATProto values (64-container decoding limit).
- [x] ATProto JSON representations and conversion (`$link` and `$bytes`).
- [x] Syntax validation of DIDs, handles, NSIDs, record keys, and restricted AT URIs.
- [x] TID parsing, formatting, and generation after a supplied previous revision.
- [x] TID generation and monotonically increasing repository revisions under a database row lock.

### Block storage

- [x] PostgreSQL `blocks` table with a binary CID primary key and binary content.
- [x] Database constraints for required fields and 36-byte CIDs.
- [x] `Atoll.Storage.put_block/2` verifies content before insertion.
- [x] Duplicate inserts succeed without replacing stored content.
- [x] `Atoll.Storage.get_block/1` retrieves exact bytes and distinguishes invalid CIDs from missing blocks.
- [x] PostgreSQL integration tests for reads, writes, duplicates, and rejected content.
- [x] Structured CBOR node storage and retrieval with CID verification and decoding validation.
- [x] Per-repository block ownership inventories for every retained revision, with indexed membership checks.
- [x] Bounded unreferenced repository-block cleanup with age grace and write serialization.
- [x] Configurable per-account byte and block quotas over retained repository history.

Block storage is currently an internal API. `put_block/2` verifies digests;
`put_node/1` also validates CBOR and decoding limits. `get_node/1` verifies stored
content against its CID before decoding it. These operations do not validate
record Lexicons or grant access to account data.

### Repositories and records

- [x] Merkle Search Tree construction, lookup, insertion, and deletion (rebuilds on mutation).
- [x] Deterministic MST serialization and reference root CID compatibility tests.
- [x] P-256 and secp256k1 in-memory key generation, compact low-S signing, and signature verification.
- [x] Version-3 commit signing and verification with expected-DID and schema checks.
- [x] Encrypted PostgreSQL signing-key storage using AES-256-GCM and a separate runtime master key.
- [x] Atomic managed repository creation and internal writes using persisted signing keys.
- [ ] Signing-key rotation, master-key rotation, and recovery workflows.
- [x] PostgreSQL repository heads and atomic record, tree, and commit updates with optional head compare-and-swap.
- [x] Internal record create, put, delete, and read operations with collection/type checks (not Lexicon validation).
- [x] Public `getRecord` and paginated `listRecords` for repository DIDs or bidirectionally verified handles and current record versions.
- [x] Historical CID versions for record reads, verified against retained signed revisions and the exact record path.
- [x] Authenticated `createRecord`, `putRecord`, and `deleteRecord`, with atomic commit/record compare-and-swap.
- [x] Authenticated atomic `applyWrites` batches with ordered results and commit compare-and-swap.
- [x] DID or bidirectionally verified handle addressing for single and batch record writes.
- [ ] Lexicon validation.
- [x] `com.atproto.repo.describeRepo` with resolved DID document, current collections, and bidirectional handle status.
- [x] In-memory CARv1 encoding and decoding with block verification and resource limits.
- [x] Consistent repository CAR export through the internal storage API.
- [x] Internal complete CAR import for existing repositories, with pinned-key verification, expected-head checks, and atomic replacement.
- [x] Authenticated `com.atproto.repo.importRepo` for existing repositories, with bounded uploads and atomic replacement.
- [x] Existing-DID migration provisioning with source-key verification and destination-key signing.
- [ ] Streaming large transfers.

`com.atproto.repo.getRecord` returns the current record unless `cid` selects a
retained version, including versions of subsequently deleted records. Historical
reads require an active repository and verify the signed commit and canonical MST;
an arbitrary stored block is not sufficient. This initial implementation scans
candidate retained revisions and loads one snapshot at a time, so histories with
many revisions or large repositories can be expensive. A dedicated version index
and history retention policy remain pending.

Single-record writes use POST with JSON and an access JWT in the Authorization
header. `repo` must be the token owner's DID or a bidirectionally verified handle
resolving to that DID. Handles are normalized and freshly verified through forward
resolution and the DID document's handle claim, before acquiring repository locks.
Forward-only aliases and handles belonging to another DID cannot authorize writes.
The live session is rechecked after resolution; returned record URIs always use
the canonical DID. DID requests do not perform handle resolution.
`collection` and `record.$type` must
match; `rkey` is required for put/delete and generated as a TID when omitted for
create. The repository must have a persisted signing key and
`ATOLL_KEY_ENCRYPTION_KEY` configured. Session authorization is rechecked while
holding the repository write lock and remains locked through commit.

`swapCommit` checks the current commit CID. Put/delete also accept `swapRecord`;
omitting it skips that check, while an explicit null on put requires the record
to be absent. Delete does not accept null. A mismatch returns `InvalidSwap`
without changing records, blob references, revisions, or events. Create rejects
an existing key. Deleting an absent record succeeds.

Create/put return `uri`, `cid`, commit metadata, and `validationStatus: "unknown"`;
delete returns commit metadata. General ATProto data-model, collection/type, blob
ownership, and record-size checks run for every write. Lexicon schema validation
is not implemented: omitted/false `validate` is accepted and `validate: true`
is rejected. Request JSON is limited to 2 MiB; encoded records retain their 1 MB
limit. Writes allow 300 requests per direct peer IP per five minutes using the
same per-node limiter as sessions, and responses use `Cache-Control: no-store`.

`POST /xrpc/com.atproto.repo.applyWrites` accepts `repo`, `writes`, optional
`swapCommit`, and optional `validate`. Each write has a `$type` of
`com.atproto.repo.applyWrites#create`, `#update`, or `#delete` (the full prefix
is required for each), a `collection`, and an `rkey` except when auto-generating
a create key. Create/update use `value` for record data. Updates require an
existing record; creates require an unused key. Duplicate paths in one batch
are rejected. Automatically generated keys are distinct within the batch.

Batches allow up to 200 operations within the shared 2 MiB request limit and
share the record-write rate limit. All operations, blob-reference changes,
revision history, and the single commit event succeed or roll back together.
Results preserve request order and carry the corresponding `#createResult`,
`#updateResult`, or `#deleteResult` type. An empty batch checks authorization and
`swapCommit`, then returns the current commit and empty results without mutation.
The same `validate: true` restriction applies to batch requests.

### Identity, accounts, and authentication

- [x] P-256 and secp256k1 multikey / `did:key` encoding and decoding with curve-point validation.
- [x] Modern DID-document parsing for expected identity, signing key, HTTPS PDS endpoint, and unverified handle claim.
- [x] Internal HTTPS resolution for `did:plc` and hostname-level `did:web`, with expected-document identity checks.
- [x] Resolver public-IPv4 address pinning, TLS hostname verification, timeouts, redirect rejection, and 256 KiB response limit.
- [ ] DID resolution caching, IPv6 and localhost development support, and independent PLC operation-log verification (currently trusts `plc.directory` over HTTPS).
- [x] DNS TXT handle resolution with HTTPS fallback, normalization, ambiguity checks, and reserved-domain rejection.
- [x] Internal bidirectional handle verification against the resolved DID document.
- [x] Public `com.atproto.identity.resolveHandle` forward lookup (does not assert bidirectional verification).
- [x] Handle-based repository reads with bidirectional verification and canonical DID record URIs.
- [ ] Handle updates, caching, and redirect support.
- [x] Authenticated account activation and deactivation with atomic status events.
- [x] Service-authenticated `createAccount` for migration of an existing DID.
- [x] Authenticated recommended DID credentials for the destination signing key and service.
- [x] Email-authorized account deletion with credential/key removal, blob cleanup, and a deleted-account event.
- [x] Internal PLC operation signing, genesis DID derivation, and predecessor signature checks.
- [x] Internal PLC genesis submission with bounded responses and exact latest-operation confirmation.
- [x] Durable genesis registration journal and encrypted PLC rotation-key retention.
- [ ] Fresh DID signup.
- [x] Internal DID-scoped password credentials with salted Argon2id hashes, bounded input, redacted inspection, and duplicate protection.
- [x] Shared configurable Cloudflare Worker email delivery client.
- [x] Email confirmation requests and one-use confirmation through the Worker.
- [x] Email updates authorized through the current confirmed address using the Worker.
- [x] Email-based password reset through the Worker with atomic session revocation.
- [x] Internal password session creation, scoped HS256 JWT verification, single-use refresh rotation, and persistent revocation.
- [x] Public DID/password session creation, refresh, inspection, and revocation endpoints, with bounded requests and per-node rate limits.
- [x] Bidirectionally verified handle/password login with normalized handles and DID-bound sessions.
- [x] Deactivated-account login, refresh, session inspection, repository import, blob upload, missing-blob inventory, and migration-scoped service tokens.
- [x] Email/password login with normalized addresses and locked ownership rechecks.
- [x] Optional email authentication factors for account-password login.
- [ ] Taken-down account session scopes.
- [x] App password creation, metadata listing, revocation, restricted sessions, and privileged service delegation.
- [ ] ATProto OAuth authorization and resource server support.
- [x] Live-session and repository ownership checks for blob uploads and single/batch record writes.
- [ ] Authorization for remaining account and repository operations.
- [ ] Account migration, identity updates, and signing-key lifecycle.
- [x] Authenticated `com.atproto.server.checkAccountStatus` with repository/blob inventory and DID service/key checks.

`Atoll.Accounts.Credentials.create/2` is a trusted internal operation that attaches
a password to an existing repository DID. It never replaces an existing credential.
`verify/2` returns only the DID on success, and the same `:invalid_credentials`
error for missing credentials and incorrect passwords. It proves password possession;
callers must separately check account status and authorization. Public signup is
not implemented for new DIDs; existing DIDs can provision migration accounts through `createAccount`.

Passwords must be valid UTF-8, 8–1024 bytes, with no trimming or normalization.
Hashes use [argon2_elixir](https://argon2-elixir.hexdocs.pm/Argon2.html) Argon2id
with random salts and the library's default work factors (64 MiB memory, three
iterations, four lanes). Only test configuration reduces the work factors.
Building this dependency requires a C compiler and `make`. Hashes are redacted
from schema inspection, and credential insertion disables query logging.
Email authentication factors are optional. Password recovery
uses the email reset endpoints described below.

### Sessions

Set `ATOLL_SESSION_SIGNING_KEY` to a separately generated, base64-encoded 32-byte
secret before starting Atoll. There is no development fallback key; session
issuance fails with `:session_configuration_missing` when no key is configured.
Keep this secret separate from the repository-key encryption key. All nodes must
share the same session key and configured PDS DID (the JWT audience).

Trusted callers can use `Atoll.Accounts.Sessions.create(did, password)` to obtain
`access_jwt` and `refresh_jwt`, `authenticate(access_jwt)` to verify a live session,
`refresh(refresh_jwt)` to rotate its tokens, and `revoke(refresh_jwt)` to revoke it.
These internal APIs also back the following public XRPC routes:

| Method | Route | Authentication / input |
| --- | --- | --- |
| POST | `/xrpc/com.atproto.server.createSession` | JSON `identifier` (hosted DID or verified handle) and `password` |
| GET | `/xrpc/com.atproto.server.getSession` | `Authorization: Bearer <accessJwt>` |
| POST | `/xrpc/com.atproto.server.refreshSession` | `Authorization: Bearer <refreshJwt>` |
| POST | `/xrpc/com.atproto.server.deleteSession` | `Authorization: Bearer <refreshJwt>` |

Creation and refresh return `did`, `handle`, `active`, `accessJwt`, and `refreshJwt`,
plus `status: "deactivated"` for deactivated accounts.
Handle login normalizes the identifier and freshly verifies its forward lookup
and the DID document's handle claim before checking that DID's password. A
forward-only alias cannot log in. Unresolvable handles, unhosted identities, and
incorrect passwords receive the same `AuthRequired` response. Credentials are
never forwarded to identity-resolution services. DID login bypasses resolution.

A handle-login response includes the freshly verified handle. DID login, session
inspection, and refresh use the last persisted identity observation, or
`handle.invalid` if none exists. Login does not update that observation or publish
identity events; the identity refresh workflow maintains it. Session inspection
omits tokens. Deletion returns an empty 200 response. Credentials must be in the JSON
body, and tokens must be in a single Authorization header; query parameters cannot
supply them. Session responses and errors use `Cache-Control: no-store`.

Session request bodies are limited to 4 KiB before general parsing. Login permits
20 attempts per direct peer IP per five minutes; other session methods share a
300-request limit per peer per five minutes. The limiter retains at most 10000
IP/bucket entries, expires old entries, and denies new keys while at capacity.
It is per-node and resets on restart. Forwarded-IP headers are deliberately ignored:
behind a reverse proxy, its clients share the proxy's limit until trusted-proxy
handling is implemented. Distributed limits and account-level throttling remain pending.
Passwords and token fields are filtered from Phoenix parameter logs.

The JWT types, scopes, and lifetimes follow the
[reference PDS token implementation](https://github.com/bluesky-social/atproto/blob/main/packages/pds/src/account-manager/helpers/auth.ts):
two-hour access tokens and ninety-day refresh tokens. JOSE verification is restricted
to HS256, with explicit audience, type, scope, identity, and time checks. PostgreSQL
stores a session ID and a SHA-256 digest of the random refresh identifier, not bearer
tokens. Refresh is serialized under a row lock and rejects the previous refresh
token immediately; retry grace periods are not implemented. Older access tokens
remain valid until expiration or revocation. Revocation invalidates all access
tokens for that session through the required database check.

Creation, refresh, and session inspection allow active or deactivated accounts.
Ordinary write authorization still requires an active repository. Deactivated
accounts may also list missing blobs and request service tokens specifically for
`com.atproto.server.createAccount`; other service-token scopes remain blocked.
Revocation and read-only `checkAccountStatus` allow existing sessions for any
repository status. Taken-down and suspended accounts cannot create or refresh
sessions. Restrictions are enforced from current database status on each request,
including sessions issued before deactivation. Sessions survive process restarts.
Changing the signing key invalidates existing tokens. Key rotation with overlap
and taken-down account session scopes remain pending. Write handlers recheck authorization inside the
write transaction; token verification alone is not write permission.

Expired session rows can be removed with `mix atoll.sessions.prune --limit 500`
(use `MIX_ENV=prod` with production configuration). Each invocation deletes one
batch of at most 1–1000 rows, oldest expiry first, and reports only the deleted
count. Rows with expiration after the batch starts are retained, and rows locked
by another transaction are skipped. Repeat or schedule the command to clear a
backlog; zero deleted rows can mean remaining expired rows are locked. Cleanup
does not revoke live sessions or alter refresh-token rotation. The internal
`Atoll.Accounts.SessionCleanup.prune_expired/1` API supports release maintenance.
Automatic in-application scheduling is not enabled.

`ATOLL_SESSION_MAX_COUNT` limits unexpired sessions per account (default 100,
range 0–1000). Login creation is serialized per repository before counting and
inserting sessions, so concurrent logins cannot bypass the cap. A full account
receives HTTP 429 `RateLimitExceeded`; revoking an existing session or waiting
for expiration frees capacity. Refresh rotates an existing session and does not
consume another slot. Lowering the limit does not revoke existing sessions;
zero disables new logins while preserving existing sessions and refreshes.

`POST /xrpc/com.atproto.server.deactivateAccount` accepts a JSON object and an
access token. Deactivation immediately blocks public repository reads and ordinary
writes; session management remains available. Optional `deleteAfter` timestamps
are validated as advisory retention hints. Atoll currently retains deactivated
accounts indefinitely and does not schedule deletion from this hint.

`POST /xrpc/com.atproto.server.activateAccount` has no input body. It resolves the
account DID, requires its signing key and PDS endpoint to match the local account
and configured public URL, and requires a decryptable stored signing key. These
checks use the existing resolver's trust model; independent PLC log/rotation-key
verification remains pending. Authorization is rechecked under the repository
write lock after resolution. Both endpoints return an empty HTTP 200 on success,
publish one durable account event per status change, and are idempotent. They
cannot undo an administrative takedown or suspension. Activation does not assert
that all referenced blob bytes have arrived; use account status and missing-blob
inventory to assess transfer progress first.

### Blobs

- [x] Internal account-scoped blob staging with MIME syntax validation, a 5 MiB size limit, and optional content-length checks.
- [x] PostgreSQL and S3-compatible byte storage, with per-blob backend metadata and verified reads.
- [x] Docker MinIO integration tests for signed storage operations, access isolation, and failure handling.
- [x] Authenticated `com.atproto.repo.uploadBlob` with bounded raw-body reads, transactional session rechecks, and per-IP rate limiting.
- [ ] Media-content sniffing and Lexicon-specific media validation.
- [x] Atomic nested record-reference tracking, ownership/metadata checks on writes, and withdrawal when the last reference is removed.
- [x] Public `com.atproto.sync.getBlob` and paginated `listBlobs`, with `since` filtering, repository status checks, and restrictive content headers.
- [x] Authenticated `com.atproto.repo.listMissingBlobs` with account-scoped CID pagination and referencing record URIs.
- [x] Internal staged-blob expiration with a 24-hour default grace period and a one-hour minimum.
- [x] Durable cleanup queue for withdrawn/expired blob ownership, shared-owner checks, PostgreSQL/S3 deletion, and retryable S3 failures.
- [x] Opt-in supervised cleanup scheduling with bounded batches, task deadlines, failure recovery, and outcome telemetry.
- [x] Transactional per-account blob byte and object-count quotas across both storage backends.
- [ ] Untracked-object inventory.

Staged blobs are private until referenced by a current record with matching
metadata. Imports may reference missing blobs; matching uploads make those blobs
available. Removing the last reference removes account ownership and public
access and queues physical byte cleanup. Existing records predating
the reference-index migration need to be rewritten or imported in a newer
snapshot before their blobs become public.

Upload raw bytes with `POST /xrpc/com.atproto.repo.uploadBlob`, an access JWT in
`Authorization: Bearer <accessJwt>`, and a concrete `Content-Type` without
parameters (defaults to `application/octet-stream` when absent). The JSON response
contains `blob`. JSON and other media bodies are stored verbatim, not parsed.
Ownership always comes from the access token. The session is checked before
reading, then checked and locked again inside the storage transaction.

Uploads accept at most 5 MiB, with or without Content-Length, and verify a supplied
length. Reads use 64 KiB chunks, a five-second per-read timeout and a thirty-second
total read budget; the bounded body is assembled in memory before storage.
Compressed request bodies are rejected. Uploads have a separate limit of 60
attempts per direct peer IP per five minutes, using the same bounded per-node
limiter as sessions. Byte/count quotas cover both PostgreSQL and S3 uploads.
Media types are syntax-checked only; bytes are not inspected or transformed.

### Blob storage configuration

`ATOLL_BLOB_STORAGE` defaults to `postgres`. Set it to `s3` to store new blob
bytes in an S3-compatible bucket while retaining ownership, MIME type, size,
and backend metadata in PostgreSQL. Repository commits and MST blocks remain
in PostgreSQL. S3 uses signed, path-style requests and fixed object keys
`blobs/<base32-CID>`; the bucket must already exist and remain private.

| Variable | Purpose |
| --- | --- |
| `ATOLL_S3_ENDPOINT` | Service origin, such as `https://s3.us-east-1.amazonaws.com` or `http://localhost:9000` for local MinIO |
| `ATOLL_S3_BUCKET` | Existing bucket name |
| `ATOLL_S3_REGION` | Signing region; defaults to `us-east-1` |
| `ATOLL_S3_ACCESS_KEY_ID` | Access key with object PUT/GET/DELETE permission |
| `ATOLL_S3_SECRET_ACCESS_KEY` | Secret key, supplied outside version control |
| `ATOLL_S3_SESSION_TOKEN` | Optional temporary-credential token |

Trusted internal callers can use:

```elixir
{:ok, blob} = Atoll.Blobs.stage(did, bytes, "image/png", content_length: byte_size(bytes))
{:ok, cid} = Atoll.CID.from_base32(blob["ref"]["$link"])
Atoll.Blobs.get_staged(did, cid)
```

The first MIME declaration for an account/CID is retained on repeat staging;
declarations must be concrete `type/subtype` values without parameters. Bytes
are never transformed. MIME syntax validation does not inspect media contents.
Existing PostgreSQL blobs remain readable when S3 is selected. Moving existing
S3 objects to another endpoint, bucket, or backend requires a separate migration;
retain their original S3 configuration until that is complete.

`ATOLL_BLOB_MAX_ACCOUNT_BYTES` defaults to 1073741824 (1 GiB), and
`ATOLL_BLOB_MAX_ACCOUNT_COUNT` defaults to 10000. Both accept nonnegative integers;
zero prevents new ownership that would exceed that limit. Each account's unique
staged and referenced blobs count toward both limits, including empty blobs toward
the count. Shared bytes count separately for each owner. Checks run under the
repository write lock before any storage write and return `:blob_quota_exceeded`.
Re-uploading an owned CID remains allowed after lowering limits. Expiration or
last-reference removal releases logical quota immediately, before physical cleanup.
These limits do not cap repository blocks, retained revisions, or orphaned bytes.

Uploads and cleanup share the repository write lock, including the S3 request,
to prevent publication racing with object deletion. Slow S3 operations therefore
delay other writes. A successful PUT followed by database failure can still leave
an untracked object. Inventory-based orphan discovery, multipart uploads,
and broader provider interoperability tests remain pending. The standard tests use a mocked S3 transport;
the optional Docker suite exercises a real MinIO server.

Trusted operators can run bounded cleanup batches:

```elixir
Atoll.Blobs.Cleanup.expire_staged(limit: 100, grace_seconds: 86_400)
Atoll.Blobs.Cleanup.collect(limit: 100)
```

Expiration removes only old, unreferenced ownership metadata and queues its bytes.
Re-uploading renews the staging grace period. Collection rechecks all accounts for
ownership of that backend/CID before deleting bytes, and leaves failed S3 deletes
queued for retry. Run collection outside any caller transaction: S3 deletion cannot
be rolled back. Collection does not discover objects orphaned before this queue
was introduced. Versioned S3 buckets retain
older object versions behind delete markers; bucket lifecycle/version cleanup is
separate from this collector.

Set `ATOLL_BLOB_CLEANUP_ENABLED=true` before starting Atoll to enable the cleanup
worker. It starts after one minute, expires up to 100 staged uploads using the
24-hour grace period, and processes up to 10 queued deletions per batch. It waits
one minute after each batch and never overlaps its own tasks. A three-minute task
deadline bounds a stalled batch; completed item transactions remain committed,
and unfinished work remains eligible for subsequent batches. The worker is
disabled automatically in the test environment; worker tests start isolated
instances explicitly.

The `[:atoll, :blobs, :cleanup]` telemetry event reports run outcome and, for
completed batches, expired, deleted, retained, failed, and skipped counts.
Enable one worker instance per deployment to avoid redundant scans; database
locking protects shared objects when collectors overlap.

### Synchronization and federation

- [x] Full repository export via `com.atproto.sync.getRepo` (in-memory, 64 MiB archive limit).
- [x] Incremental repository exports using `since`, backed by per-repository revision block sets; unknown revisions return a full snapshot.
- [ ] Revision-history compaction and scalable block-reference indexing (block sets are currently retained indefinitely).
- [x] `getLatestCommit`, `getRepoStatus`, and paginated `listRepos` sync endpoints with persistent repository status.
- [x] `com.atproto.sync.getRecord` compact signed existence and absence proofs.
- [x] `com.atproto.sync.getBlocks` for current and retained historical repository blocks (1–100 CIDs; repeated `cids` query parameters).
- [x] Export consistency checks against the signed commit, tree root, and revision.
- [x] Internal deactivation, suspension, takedown, and reactivation; inactive repositories reject public reads, exports, and ordinary record writes. Authenticated migration imports/uploads allow deactivated accounts only.
- [x] Historical block retrieval with signed-commit and canonical-tree membership checks, including deleted records and prior MST nodes.
- [x] Internal durable event sequencing and cursor replay, recorded atomically with repository creation, writes, imports, and status changes.
- [ ] Event retention / compaction and higher-throughput sequencing (writes currently share a PostgreSQL transaction advisory lock to preserve commit order).
- [x] `com.atproto.sync.subscribeRepos` binary WebSocket stream with exclusive resume cursors, live delivery, and account status events.
- [x] Invalid/future cursor errors, bounded replay backlog, idle pings, and current-availability filtering for repository data.
- [x] Wire-format commit, sync, account, and identity event encoding, plus CBOR stream/error framing.
- [x] Commit CARs with full MSTs, changed records, prior roots, and operation metadata; oversized commits fall back to commit-only sync messages.
- [ ] Compact inductive commit proofs (event encoding currently includes the complete MST).
- [x] Internal `Atoll.Identity.Updates.refresh/2`: resolves hosted identities, verifies claimed handles, and atomically records changed observations with durable identity events.
- [x] Opt-in supervised identity refresh scheduling, with one task at a time, timeouts, sweep retries, and outcome telemetry.
- [ ] Authenticated identity-management endpoints and distributed refresh coordination.
- [ ] Relay discovery / crawl requests and federation interoperability tests.
- [x] `com.atproto.server.getServiceAuth` issues short-lived account-signed service JWTs.
- [x] Internal incoming account service-JWT verification with exact audience/method checks and persistent replay protection.
- [x] Service-authenticated migration account creation.
- [ ] Request proxying to AppViews and other services.

Historical `getBlocks` reads are limited to active repositories and return only
requested blocks in a rootless CAR. Deleted record bytes remain publicly retrievable
while their signed revisions are retained. Candidate revisions are selected by
their block indexes, then their commits and canonical trees are verified before
granting access; shared storage or index membership alone is insufficient. A
missing or foreign CID rejects the whole request. Historical verification can
load multiple complete retained trees, so its cost grows with repository history;
scalable membership indexes and history compaction remain pending.

`GET /xrpc/com.atproto.server.getServiceAuth` normally requires an active account's access
token and a stored repository signing key. Supply `aud` as a DID or DID with a
service fragment, optionally `lxm` as an XRPC method NSID and `exp` as Unix epoch
seconds. Tokens default to 60 seconds; method-less tokens cannot exceed 60 seconds,
and method-bound tokens cannot exceed one hour. Expired or excessive timestamps
return `BadExpiration`. Protected account-management methods are rejected
case-insensitively. The endpoint shares session request limits and disables caching.

Issued JWTs use ES256K or ES256 according to the account key and include `iss`,
`aud`, `iat`, `exp`, a random `jti`, and optional `lxm`. Authorization and key access
occur in one transaction. Tokens already issued remain cryptographically valid
until expiration even if the originating session is revoked; receiving services
must enforce audience, method, expiration, and their own authorization policy.
Atoll does not yet accept service JWTs as local access tokens or proxy requests.
Deactivated accounts can request only the `com.atproto.server.createAccount`
method for migration. Taken-down sessions remain pending. App-password delegation requires an explicit method; standard app passwords cannot delegate chat methods.

The internal `Atoll.Accounts.ServiceTokens.authenticate/4` verifier accepts account
service JWTs with `typ: JWT`, ES256K/ES256, and default or explicit `kid: #atproto`.
It resolves the issuer's DID document without requiring a PDS service, rejects
ambiguous account keys, and requires exact expected audience and method matches.
`iat`, `exp`, and `jti` are required, with a maximum one-hour lifetime and up to
30 seconds of issuer clock skew. Bare audiences are accepted only when the caller
explicitly expects that exact bare DID; they do not match service fragments.
Duplicate JSON fields and unsupported protected headers are rejected.

Successful verification consumes the issuer/nonce once through a unique PostgreSQL
digest row. No bearer token is persisted. Callers can include verification in their
operation transaction so rollback also restores the ability to retry. Expired replay
markers can be removed in bounded batches with
`Atoll.Accounts.ServiceTokens.prune_expired/1` (default 500, maximum 1000).
Automatic replay-marker cleanup scheduling remains pending. Migration account creation uses this verifier, which
uses the existing resolver's HTTPS trust model, not independent PLC log validation.

For local development, connect to
`ws://localhost:4000/xrpc/com.atproto.sync.subscribeRepos?cursor=0`.
Omit `cursor` to start at the current stream position; otherwise pass the last
received sequence number to replay later events. Messages are binary frames with
two concatenated CBOR objects (header and body), not JSON or Phoenix channels.
Idle connections poll PostgreSQL every 500 ms and send a ping every 15 seconds.
Connections more than 10,000 persisted events behind receive `ConsumerTooSlow`
and close; sequence gaps do not count toward this limit. Replay skips commit and
sync data for currently inactive repositories, but still emits account and identity events.
Internet deployment requires WSS termination; connection quotas, event retention,
and federation interoperability testing remain pending.

Identity refreshes announce changes in the resolved handle, signing key, or PDS
endpoint. Unverified handles are emitted as `handle.invalid`; failed DID lookups
preserve the previous observation. Refreshes do not rotate the repository's
pinned signing key or move accounts.

Set `ATOLL_IDENTITY_REFRESH_ENABLED=true` before starting Atoll to enable automatic
refreshes. The worker starts after one second, waits one second between identities,
and waits five minutes after each complete sweep. Each refresh has a 20-second
deadline; failures are retried on the next sweep. All hosted identities, including
inactive ones, are visited in DID order. The worker runs independently per node;
enable it on one application instance until distributed coordination exists.
Restarts begin a new sweep, and unchanged observations do not produce duplicate
events. The `[:atoll, :identity, :refresh]` telemetry event reports a count and
`published`, `unchanged`, `failed`, or `timeout` outcome.

### Operations

- [x] `mix precommit` checks compilation warnings, unused dependency locks, formatting, and tests.
- [x] GitHub Actions runs checks and the Docker MinIO integration suite on every push (also available manually).
- [x] Session, blob-upload, and record-write rate limits and bounded request bodies.
- [ ] General API rate limits, distributed limits, and trusted-proxy client IP handling.
- [ ] Administrative account controls and takedowns.
- [ ] Production configuration, HTTPS deployment, and signing-key protection.
- [ ] Database and blob backup / restore workflow.
- [x] `GET /health/ready` database connectivity readiness with bounded queries and outcome telemetry.
- [ ] Comprehensive operational monitoring and alerting.
- [ ] End-to-end compatibility tests with existing ATProto clients and servers.

## Local development

Use `GET /health` for process liveness and `GET /health/ready` for PostgreSQL
connectivity readiness. Both responses disable caching. Readiness runs `SELECT 1`
with a one-second query timeout and no pool queueing, returning HTTP 200 with
`{"status":"ok"}` or HTTP 503 with `{"status":"unavailable"}`. A busy pool can
therefore report unavailable. Database errors and credentials are never included
in the response. This probe does not verify migrations, signing keys, S3, or
external identity services. Configure deployment probe intervals and failure
thresholds accordingly; it is not a complete production-readiness assessment.
The `[:atoll, :readiness, :check]` telemetry event includes `count`, `duration`
(native monotonic time units), and an `outcome` of `ready` or `unavailable`.

Install Elixir / Erlang and PostgreSQL. The project declares Elixir `~> 1.17`; see `mix.exs` for dependency requirements.

Configure `Atoll.Repo` in `config/dev.exs` and `config/test.exs` for your local PostgreSQL role and credentials. Keep development and test database names separate. Configure the development server metadata under `config :atoll, :pds`.

Runtime metadata can be configured with `ATOLL_PDS_DID` and
`ATOLL_AVAILABLE_USER_DOMAINS` (comma-separated, dot-prefixed suffixes such as
`.example.com,.example.org`; empty clears the list). Suffixes are normalized to
lowercase and deduplicated. Unset values preserve development/test configuration.
Production requires an explicit `ATOLL_PDS_DID` and `PHX_HOST`; it advertises no
handle domains unless configured. `PHX_HOST` must be a DNS hostname without a
scheme, port, or path and sets Phoenix's public HTTPS URL on port 443. Existing
production database and secret-key configuration is still required.

These settings advertise metadata; the DID endpoint additionally requires a stable
server signing key and matching HTTPS public hostname. They do not provision
DNS, implement signup, or verify domain ownership. `describeServer` also reports
the enforced `blobUploadLimit` of 5,242,880 bytes. The server DID is the session JWT
audience, so changing it invalidates existing session tokens.

```sh
mix setup
mix phx.server
```

In another terminal:

```sh
curl http://localhost:4000/health
curl http://localhost:4000/xrpc/com.atproto.server.describeServer
```

The development server description currently returns:

```json
{"did":"did:web:localhost","availableUserDomains":[]}
```

## Encrypted signing keys

Set `ATOLL_KEY_ENCRYPTION_KEY` to a base64-encoded random 32-byte master key
before starting Atoll. There is no default. Keep it outside version control and
back it up separately from PostgreSQL: losing it makes stored signing keys
unrecoverable. Changing it does not rotate existing encrypted keys.

With the master key configured, trusted internal callers can use:

```elixir
{:ok, head} = Atoll.Repositories.create_managed(did)
Atoll.Repositories.apply_managed_writes(did, operations, swap_commit: head.head)
```

For an existing repository whose private key is still available,
`Atoll.KeyVault.store(did, key)` persists it only if it matches the pinned public
key. Existing encrypted keys cannot be overwritten. These internal functions do
not authorize accounts; HTTP record writes authorize the repository owner's session.

## Checks

### Internal repository restore

For an existing repository, a trusted caller can import a complete CAR snapshot:

```elixir
{:ok, head} = Atoll.Repositories.get_head(did)
{:ok, archive} = File.read("repository.car")
Atoll.Repositories.import_archive(did, archive, head.head)
```

The import uses the stored public key, requires the expected head to remain
unchanged, and replaces records and the head in one transaction. It accepts newer
revisions or an identical-head retry. Archives must include the full tree and all
records; referenced blobs and external records are not required. Unreferenced
blocks are discarded. Local limits are 64 MiB per archive, 1 MB per record, and
five minutes of future revision tolerance. This API does not authorize users,
resolve identities, rotate keys, or validate record Lexicons.

### Authenticated repository import

`POST /xrpc/com.atproto.repo.importRepo` accepts a complete CAR for the access
token owner's existing active or deactivated repository. Send `Authorization: Bearer <accessJwt>`,
`Content-Type: application/vnd.ipld.car`, and a matching `Content-Length`.
Compressed requests are not supported. Success returns an empty HTTP 200 response.

The endpoint verifies the snapshot's DID and signature against the repository's
pinned public key. It captures the current head before reading the body and
rejects replacement if another write changes it during ingestion or verification.
Authorization is checked again under the write lock. Records, blob references,
the head, and the sync event change atomically; identical-head retries emit no
additional event. Older revisions are rejected.

Uploads are buffered in memory with a 64 MiB limit, a five-second per-read timeout,
and a 30-second overall read budget. Imports allow ten attempts per direct peer IP
per five minutes on each server process. Blob bytes must be transferred separately;
streaming migration remains pending.

For migration, `createAccount` requires an existing DID, a bidirectionally verified
handle, a password, and a one-use service JWT for this PDS and the createAccount
method. Email is optional. It creates a deactivated account and a new encrypted
signing key. `getRecommendedDidCredentials` returns that key and this PDS endpoint;
Migration PLC rotation keys and authenticated update submission remain pending. Before activation,
imports may use the source key pinned during provisioning: Atoll verifies the CAR,
re-signs its tree with the destination key, and tracks source revisions to reject
rollback. Exact retries are idempotent. After updating the public DID document,
activation checks the destination key and endpoint and clears source-key trust.

After import, `GET /xrpc/com.atproto.repo.listMissingBlobs` with an access token
lists referenced CIDs that lack matching account-owned blob metadata. It accepts
`limit` (1–1000, default 500) and an exclusive CID `cursor`, returning each CID
once with a referencing `recordUri`. Uploading the matching bytes and MIME type
removes that blob from the results. Metadata mismatches remain listed. This is
an inventory of current database references, not a physical storage integrity
scan; missing or corrupted backend objects require separate operational checks.
It accepts active or deactivated accounts and shares the session endpoint's
300-request per-IP, per-five-minute limit. Pagination reflects current state
rather than a snapshot across requests.

`GET /xrpc/com.atproto.server.checkAccountStatus` accepts an existing access token,
including for inactive accounts, and reports activation, current commit/revision,
stored blocks referenced by retained repository revisions, current record count,
distinct referenced blob CIDs, and account-owned blob count (including staged
uploads). Counts describe database inventory, not backend byte integrity.
`privateStateValues` is zero because private application state is not implemented.
`validDid` checks the resolved signing key against the pinned repository key and
the DID's PDS endpoint against Phoenix's configured public endpoint URL. Resolution
failure returns `validDid: false`. PLC operation-log/rotation-key authority and
private-key availability are not checked. Remote resolution runs before inventory
locks; the session is checked again before returning account data. This endpoint
shares the session query rate limit and does not itself grant write access.
Deactivated accounts may separately log in, refresh, import a repository, and
upload blobs. Taken-down and suspended accounts may not. Migration writes preserve
deactivation: public reads and public sync data remain blocked until activation.
Ordinary create/put/delete/applyWrites calls remain blocked while deactivated.

### Validation

```sh
mix precommit
```

The test alias creates the test database and applies pending migrations. Database tests use Ecto's SQL sandbox to roll back their changes.

### MinIO integration tests

With Docker running and the local test PostgreSQL database available:

```sh
bash scripts/test_minio.sh
```

The script builds a test image from MinIO's pinned
`RELEASE.2025-09-07T16-13-09Z` source release, starts a disposable container on a
random localhost port, waits for readiness, and runs the `minio`-tagged tests.
The first build downloads Go dependencies and can take several minutes; Docker
caches the image for subsequent runs. Test credentials are fixed and only used
in this loopback-bound container. Objects live in temporary memory-backed storage;
the container is stopped and removed on exit. No production S3 credentials or
buckets are used. The tests cover SigV4 uploads and downloads, the 5 MiB boundary,
private buckets, account ownership, invalid credentials, missing buckets, and
corrupt or missing objects. These tests are excluded from `mix precommit`.

GitHub Actions builds this image with Buildx and saves all build stages to the
GitHub Actions layer cache, including the Go compilation stage. It loads the
result into Docker and runs `bash scripts/test_minio.sh --skip-build` to avoid a
second build. The flag requires the tagged image to exist locally. Local runs
without the flag still build normally; Dockerfile changes invalidate the relevant
cached layers automatically.

## Protocol references

- [AT Protocol overview](https://atproto.com/guides/overview)
- [Data model and CID formats](https://atproto.com/specs/data-model)
- [Repository format](https://atproto.com/specs/repository)
- [Synchronization](https://atproto.com/specs/sync)
- [OAuth](https://atproto.com/specs/oauth)

## License

[MIT](LICENSE)

### Email delivery

All email features must use `Atoll.Email.deliver/3`, which submits messages to an
external Cloudflare Worker. Configure both settings before starting Atoll:

```sh
export ATOLL_EMAIL_WORKER_URL=https://your-worker.example.com/send
export ATOLL_EMAIL_WORKER_TOKEN='<shared bearer secret>'
```

Alternatively set `config :atoll, :email_worker, url: "https://...", token: "..."`
in runtime configuration using your secret source. Neither setting configured
means delivery is disabled; partial or malformed environment configuration fails
startup. The endpoint must use HTTPS without embedded credentials, query, or fragment.
There is no SMTP or direct-provider fallback.

The Worker API contract is an authenticated POST with `Authorization: Bearer ...`,
`Idempotency-Key: <opaque message ID>`, and JSON:

```json
{"to":"owner@example.com","subject":"Confirm your email","text":"Your code is ..."}
```

The Worker owns the sender address and provider credentials, validates the shared
secret, and deduplicates requests by idempotency key. Return 200, 202, or 204 only
when accepting responsibility for delivery. Atoll treats 408, 429, transport errors,
and 5xx responses as unavailable; other responses are rejected. Response bodies
are discarded. Redirects and automatic retries are disabled. Callers must retain
the same key for retries of a logical message, including ambiguous timeouts.

`POST com.atproto.server.requestEmailConfirmation` takes a live access token and
no body. It sends a code to the account profile's email using the Worker.
`POST com.atproto.server.confirmEmail` takes the same authentication and a JSON
object containing `email` and `token`. Codes contain 192 bits of randomness,
expire after 15 minutes, and are stored only as email-bound hashes. Confirmation
consumes the code atomically. Requests are limited to one per account per minute
across server instances, in addition to the session endpoint IP limits. Resending
replaces the old code. Already-confirmed requests succeed without sending email.
Active and deactivated accounts can confirm; suspended and taken-down accounts cannot.
Session responses include `email` and `emailConfirmed` when a profile has an email.

Delivery is synchronous after token persistence and outside database locks. A
Worker failure returns 503, leaves the email unconfirmed, and retains the cooldown;
a new request after one minute can issue a replacement code. A crash between
persistence and delivery requires another request. Durable retry scheduling and the external Worker deployment remain
pending. No real email is sent by the tests.


`POST com.atproto.server.requestEmailUpdate` takes a live management access token
and no body. It returns `tokenRequired: false` for an unconfirmed or missing email.
For a confirmed address, it sends a one-use change code to that address through
the Worker and returns `tokenRequired: true`. These codes expire after 15 minutes;
requests have a persistent one-minute per-account cooldown.

`POST com.atproto.server.updateEmail` takes JSON `email` and, for confirmed
accounts, `token`. Addresses use the same normalization and uniqueness rules as
provisioning. A changed address becomes unconfirmed, and outstanding confirmation
and change codes are cleared atomically. A duplicate address rejects the change
without consuming its code. An unchanged normalized address preserves confirmation
but still consumes the change code. Confirm the new address using the separate
confirmation endpoints. `emailAuthFactor: true` enables an email login factor only when keeping the
current confirmed address. Disabling it requires the same current-email change
authorization; changing addresses disables it until explicitly re-enabled. Both email update endpoints require a live session;
service tokens cannot authorize them.


`POST com.atproto.server.requestPasswordReset` accepts JSON `email` without a
session. For eligible active/deactivated accounts it sends a 15-minute reset code
through the Worker. Codes contain 192 bits of randomness; only a purpose-specific
SHA-256 digest is persisted. Requests share the 20-per-five-minute direct-IP login
bucket, and each account has a persistent one-minute email cooldown. Unknown,
ineligible, throttled, and provider-failed requests all return empty HTTP 200;
missing Worker configuration returns 503 for every address. Delivery outcomes
emit `[:atoll, :email, :password_reset]` telemetry without account identifiers.
Synchronous delivery timing can still differ by account existence; a durable
outbox remains pending.

`POST com.atproto.server.resetPassword` accepts JSON `token` and `password` without
a session. It validates the code, hashes the new password outside database locks,
then rechecks the code under the account lock. Credential replacement, code
consumption, revocation of all account sessions, and clearing outstanding email
management codes happen atomically. Email changes invalidate outstanding recovery
codes. A reset does not activate the account or change its email confirmation.
Login rechecks the verified credential under its account lock to prevent an old
password check from creating a session after recovery. Expired or consumed codes
cannot be reused. Suspended and taken-down accounts cannot redeem reset codes.


`createSession` also accepts a local account email as its `identifier`. Email
normalization matches provisioning and updates; it does not require DNS resolution
or send an email. The password is still required, and email confirmation is not a
prerequisite for login. Incorrect passwords and unknown emails share the same
credential error, with dummy Argon2 work for unknown addresses. Email ownership
is rechecked under the account lock before session insertion. Updated addresses
stop resolving to the old account. Existing account status checks, session caps,
and direct-peer login limits apply. Request logs redact the identifier.


### App passwords

With a full account session, use `POST com.atproto.server.createAppPassword` with
JSON `name` and optional `privileged` (default false). The response includes the
password only once, plus its name, creation time, and privilege flag.
`GET com.atproto.server.listAppPasswords` returns metadata without passwords.
`POST com.atproto.server.revokeAppPassword` takes JSON `name` and atomically
removes that credential and all of its sessions. Revoking an absent name succeeds.
Names are case-sensitive, nonblank UTF-8 strings up to 128 bytes without control
characters. Accounts may have at most 100 app passwords.

Generated passwords contain 160 random bits encoded as eight groups of four
lowercase base32 characters. Only a purpose- and account-bound SHA-256 digest is
stored. Log in through `createSession` using DID, verified handle, or local email
and the app password. App sessions count toward the ordinary session limit.
They use `com.atproto.appPass` or `com.atproto.appPassPrivileged` access scopes;
refresh preserves the persisted scope. Every access check compares the JWT scope
with the session row, and session creation rechecks that the app credential has
not been revoked.

Both scopes permit ordinary record writes, blob uploads, session inspection,
refresh, and logout. Account-management operations, repository migration imports,
and app-password management require a full account session. `getServiceAuth`
requires an explicit method for app sessions, rejects migration account creation,
and permits `chat.bsky.*` methods only for privileged app passwords. Existing
protected-method restrictions still apply. Already-issued service JWTs remain
valid until their short expiry. Password recovery revokes all app credentials as
well as sessions. OAuth and taken-down account scopes remain pending.


### Email authentication factors

Enable `emailAuthFactor` through `updateEmail` after confirming the address,
using a code from `requestEmailUpdate`. Account-password login then returns
`AuthFactorTokenRequired` and sends a login code through the Worker. Retry
`createSession` with the same identifier/password and `authFactorToken`.
Incorrect passwords do not trigger email. Challenges have 192 bits of randomness,
expire after 15 minutes, and have a persistent one-minute per-account cooldown.
Resending replaces the old code. Only a digest bound to the DID, email, and
password credential is stored. Codes are consumed atomically with session creation;
failed transactions preserve them. Code expiry or mismatch returns `AuthRequired`.
Worker failures return 503 without issuing a session.

An address change or factor-setting update clears outstanding login challenges.
Password recovery clears them while preserving an enabled factor. Session creation
rechecks the current factor setting under the account lock, including for password
checks that started before it was enabled. Existing sessions continue to refresh;
app-password logins bypass the email challenge but retain restricted scopes.
Session responses with an email include `emailAuthFactor`. Automatic email retries
and OAuth remain pending.


### Account deletion

`POST com.atproto.server.requestAccountDelete` requires a live full-account access
token and no body. It sends a one-use deletion code through the configured Worker,
with a 15-minute expiry and persistent one-minute request cooldown. An existing
full session can request deletion even if the account is deactivated, suspended,
or taken down. App-password sessions cannot request deletion.

`POST com.atproto.server.deleteAccount` accepts JSON `did`, the account `password`,
and the emailed `token`. These body credentials authorize the operation; a bearer
token is not required. App passwords are rejected. Successful deletion atomically
removes the repository head, indexed records and revision metadata, encrypted
signing key, identity observation, profile, credentials, and sessions. Blob
ownership is withdrawn and physical bytes enter the existing durable cleanup
queue; bytes still owned by another account are retained. Run the cleanup worker
or explicit collection to finish physical blob cleanup.

Prior firehose events for the DID are removed, and a new account event reports
`active: false, status: "deleted"`. This prevents old commits from reappearing if
the same DID is later provisioned again. Unowned repository block bytes can be reclaimed with the bounded block cleanup
command after its age grace period; backups and copies held by other services are
outside this deletion operation. Email changes and password recovery invalidate
outstanding deletion codes. Deletion requests use the bounded session parser;
final deletion shares the direct-IP login attempt limit. No external PLC identity
is tombstoned or deleted by this operation.


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

Historical revisions remain owners even after a record is updated/deleted or an
account is deactivated. Account deletion removes those ownership inventories,
allowing unique blocks to expire while other accounts protect shared blocks.
Raw blob bytes are deliberately handled by the separate blob cleanup queue.
Standalone internal `Storage.put_node` writes have no ownership until attached to
a repository; callers must not rely on unowned blocks surviving beyond the grace
period. Revision compaction and normalized reference indexing remain pending.


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
be rejected; raise the limit or delete the account until history compaction is
available. Unowned blocks and raw blob bytes do not count toward repository quota.
Usage currently scans and deduplicates retained revision inventories; incremental
accounting is future performance work. Internal inventory is available through
`Atoll.Repositories.Quota.usage/1`.


### Public server DID document

`GET /.well-known/did.json` publishes the server service identity when
`ATOLL_PDS_DID=did:web:<hostname>` matches the configured HTTPS endpoint hostname
and the request host. Set `ATOLL_PDS_SIGNING_KEY` to a base64-encoded 32-byte
secp256k1 private key. Generate it once, store it in your deployment secret store,
and reuse it across restarts. For example, generate a key locally with:

```sh
mix run --no-start -e 'key = Atoll.SigningKey.generate(); IO.puts(Base.encode64(key.private))'
```

This service key is separate from session JWT signing, account repository keys,
and the key-vault encryption key. The document exposes only its Multikey public
key, the configured DID, and the `#atproto_pds` service URL. It uses
`application/did+ld+json`, allows public cross-origin reads, and caches for five
minutes. No request header can override the configured endpoint or key.

Missing key configuration returns an uncached 503. A hostname mismatch, non-HTTPS
endpoint, path-based DID, localhost DID, or non-web DID returns 404 here. Those
identities are not automatically provisioned by this endpoint; externally managed
DIDs still need their own publication mechanism. DNS, TLS certificates, deployment,
and service-key rotation coordination remain operator responsibilities.


### PLC operation primitives

`Atoll.Identity.PLC.Operation` constructs signed ATProto genesis operations using
separate repository signing and PLC rotation keys. It derives the DID and operation
CID from canonical signed DAG-CBOR, verifies modern and legacy genesis operations,
and checks update/tombstone signatures against an already-trusted predecessor.
Both secp256k1 and P-256 rotation keys are supported. Signature encodings must be
canonical unpadded base64url with low-S compact ECDSA values. Signed operations
are limited to 7500 bytes; current regular operations require 1–5 distinct rotation
keys. Legacy operations can be verified but are not generated.

Tests use the PLC project's pinned interoperability fixtures (with provenance and
license in `test/fixtures/plc`) to check exact DIDs, CIDs, signatures, and malformed
signature rejection. These primitives do not validate recovery windows or audit-log
nullification, and are not yet used for public signup.
Persist a signed genesis operation before attempting registration: signing it again
can produce different bytes and therefore a different DID. Full audit validation,
automatic registration retries and fresh-account provisioning remain pending.


### PLC directory submission

`Atoll.Identity.PLC.Client.submit_genesis/3` validates a supplied signed genesis,
submits those exact operation fields, then fetches `/log/last` to confirm the
operation CID and genesis signature. A timeout or duplicate-submission error can
still succeed if the directory confirms the exact genesis. A different latest
operation fails closed; successful submission alone never authorizes activation.

Set `ATOLL_PLC_DIRECTORY_URL` to a trusted HTTPS directory origin (default
`https://plc.directory`), also available as `config :atoll, :plc_directory_url`.
This setting currently affects submission only; DID resolution still uses the
public directory. Redirects and automatic retries are disabled. Each request has
a 10-second overall deadline and a 64 KiB response limit; compressed log responses
are rejected. No directory requests run at startup. Tests use a mock transport.

The caller must persist and reuse the signed genesis before calling this client.
It does not store operations, reserve handles, schedule retries, or create accounts.
`Atoll.Identity.PLC.Registrations` supplies the internal durable journal described
below. Public signup integration and automatic retries remain pending.


### Durable PLC registration journal

`Registrations.stage/3` stores the exact signed genesis and a retained rotation key
inside the caller's account-provisioning transaction. It requires a deactivated
repository, a matching profile handle and repository public key, and a recoverable
repository signing key. Profile uniqueness reserves the handle and email. The
operation is insert-only; repeated staging of the same operation and rotation key
preserves the existing encryption envelope.

Rotation keys use AES-256-GCM with `ATOLL_KEY_ENCRYPTION_KEY`, a distinct purpose
label, and authenticated DID, operation CID, curve and public key. Private keys
are never stored in plaintext. Database backups require the master key to recover
both repository and PLC rotation keys. Rotation/master-key migration is pending.

After committing, `Registrations.submit/2` loads the stored operation, checks both
keys remain recoverable, and uses the directory client. It rejects calls inside a
repository transaction. Failed requests leave the journal available for an exact
retry; confirmed submissions retain the first confirmation timestamp. Confirmation
never activates an account or issues sessions, and is historical acceptance evidence,
not a substitute for checking current identity state. Account deletion cascades to
the local journal and encrypted rotation key; it does not tombstone the public DID.

These APIs are internal and do not authorize callers. No registration scheduler or
public fresh-signup route invokes them yet. No live PLC registrations are performed
by the tests, migrations, or startup.
