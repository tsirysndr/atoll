# Atoll

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
- [ ] Public server identity and domain configuration (development uses `did:web:localhost`).
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
- [ ] Repository ownership and block references.
- [ ] Unreferenced-block cleanup and storage quotas.

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
- [ ] Record writes and deletion (`createRecord`, `putRecord`, `deleteRecord`, `applyWrites`).
- [x] `com.atproto.repo.describeRepo` with resolved DID document, current collections, and bidirectional handle status.
- [x] In-memory CARv1 encoding and decoding with block verification and resource limits.
- [x] Consistent repository CAR export through the internal storage API.
- [x] Internal complete CAR import for existing repositories, with pinned-key verification, expected-head checks, and atomic replacement.
- [ ] Authenticated `com.atproto.repo.importRepo`, new-account migration, and streaming large transfers.

`com.atproto.repo.getRecord` returns the current record unless `cid` selects a
retained version, including versions of subsequently deleted records. Historical
reads require an active repository and verify the signed commit and canonical MST;
an arbitrary stored block is not sufficient. This initial implementation scans
candidate retained revisions and loads one snapshot at a time, so histories with
many revisions or large repositories can be expensive. A dedicated version index
and history retention policy remain pending.

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
- [ ] Account creation, activation, deactivation, and deletion.
- [x] Internal DID-scoped password credentials with salted Argon2id hashes, bounded input, redacted inspection, and duplicate protection.
- [ ] Email verification, password changes, and account recovery.
- [x] Internal password session creation, scoped HS256 JWT verification, single-use refresh rotation, and persistent revocation.
- [ ] Public session creation, refresh, inspection, and revocation endpoints.
- [ ] App passwords.
- [ ] ATProto OAuth authorization and resource server support.
- [ ] Authorization checks for account and repository operations.
- [ ] Account migration, identity updates, and signing-key lifecycle.

`Atoll.Accounts.Credentials.create/2` is a trusted internal operation that attaches
a password to an existing repository DID. It never replaces an existing credential.
`verify/2` returns only the DID on success, and the same `:invalid_credentials`
error for missing credentials and incorrect passwords. It proves password possession;
callers must separately check account status and authorization. No public signup or
login route is exposed yet.

Passwords must be valid UTF-8, 8–1024 bytes, with no trimming or normalization.
Hashes use [argon2_elixir](https://argon2-elixir.hexdocs.pm/Argon2.html) Argon2id
with random salts and the library's default work factors (64 MiB memory, three
iterations, four lanes). Only test configuration reduces the work factors.
Building this dependency requires a C compiler and `make`. Hashes are redacted
from schema inspection, and credential insertion disables query logging. Rate
limits, email/handle login, public session endpoints, password changes, and recovery remain pending.

### Internal sessions

Set `ATOLL_SESSION_SIGNING_KEY` to a separately generated, base64-encoded 32-byte
secret before starting Atoll. There is no development fallback key; session
issuance fails with `:session_configuration_missing` when no key is configured.
Keep this secret separate from the repository-key encryption key. All nodes must
share the same session key and configured PDS DID (the JWT audience).

Trusted callers can use `Atoll.Accounts.Sessions.create(did, password)` to obtain
`access_jwt` and `refresh_jwt`, `authenticate(access_jwt)` to verify a live session,
`refresh(refresh_jwt)` to rotate its tokens, and `revoke(refresh_jwt)` to revoke it.
These are internal APIs; they do not yet provide HTTP login, handle/email lookup,
or complete account management.

The JWT types, scopes, and lifetimes follow the
[reference PDS token implementation](https://github.com/bluesky-social/atproto/blob/main/packages/pds/src/account-manager/helpers/auth.ts):
two-hour access tokens and ninety-day refresh tokens. JOSE verification is restricted
to HS256, with explicit audience, type, scope, identity, and time checks. PostgreSQL
stores a session ID and a SHA-256 digest of the random refresh identifier, not bearer
tokens. Refresh is serialized under a row lock and rejects the previous refresh
token immediately; retry grace periods are not implemented. Older access tokens
remain valid until expiration or revocation. Revocation invalidates all access
tokens for that session through the required database check.

Creation, access verification, and refresh currently require an active repository;
revocation is also allowed for inactive repositories. Sessions survive process
restarts. Changing the signing key invalidates existing tokens. Key rotation with
overlap, expired-session cleanup, session-count limits, and restricted sessions for
inactive accounts remain pending. Future write handlers must enforce authorization
again inside the write transaction; token verification alone is not write permission.

### Blobs

- [x] Internal account-scoped blob staging with MIME syntax validation, a 5 MiB size limit, and optional content-length checks.
- [x] PostgreSQL and S3-compatible byte storage, with per-blob backend metadata and verified reads.
- [x] Docker MinIO integration tests for signed storage operations, access isolation, and failure handling.
- [ ] Authenticated blob upload endpoint and media-content validation.
- [x] Atomic nested record-reference tracking, ownership/metadata checks on writes, and withdrawal when the last reference is removed.
- [x] Public `com.atproto.sync.getBlob` and paginated `listBlobs`, with `since` filtering, repository status checks, and restrictive content headers.
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
snapshot before their blobs become public. Authenticated uploads remain pending.

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
- [x] `com.atproto.sync.getBlocks` for current repository blocks (1–100 CIDs; repeated `cids` query parameters).
- [x] Export consistency checks against the signed commit, tree root, and revision.
- [x] Internal deactivation, suspension, takedown, and reactivation; inactive repositories reject public reads, exports, writes, and imports.
- [ ] Historical block retrieval.
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
- [ ] Service authentication and request proxying to AppViews and other services.

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
- [ ] Rate limiting and request / upload size limits.
- [ ] Administrative account controls and takedowns.
- [ ] Production configuration, HTTPS deployment, and signing-key protection.
- [ ] Database and blob backup / restore workflow.
- [ ] Database readiness checks and operational monitoring.
- [ ] End-to-end compatibility tests with existing ATProto clients and servers.

## Local development

Install Elixir / Erlang and PostgreSQL. The project declares Elixir `~> 1.17`; see `mix.exs` for dependency requirements.

Configure `Atoll.Repo` in `config/dev.exs` and `config/test.exs` for your local PostgreSQL role and credentials. Keep development and test database names separate. Configure the development server metadata under `config :atoll, :pds`.

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
key. Existing encrypted keys cannot be overwritten. These functions do not
authorize accounts; authenticated HTTP writes remain pending.

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

## Protocol references

- [AT Protocol overview](https://atproto.com/guides/overview)
- [Data model and CID formats](https://atproto.com/specs/data-model)
- [Repository format](https://atproto.com/specs/repository)
- [Synchronization](https://atproto.com/specs/sync)
- [OAuth](https://atproto.com/specs/oauth)

## License

[MIT](LICENSE)
