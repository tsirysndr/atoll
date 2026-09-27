# Feature record

The complete feature record: every implemented capability with its scope notes, kept as the project's development history.

## Feature checklist

Every item below is implemented in this repository. This is the project's development record, not a claim of complete protocol conformance; scope decisions and deliberate design tradeoffs are recorded inline.

### Server foundation

- [x] Phoenix API application with a PostgreSQL connection through Ecto.
- [x] Database migrations and isolated database tests.
- [x] `GET /health` HTTP liveness endpoint (does not check database readiness).
- [x] `GET /xrpc/_health` version and database probe, plus the reference `robots.txt` allowing public-API crawling.
- [x] `GET /tls-check` on-demand certificate approval for the server host and completed hosted-handle hosts, mirroring the reference PDS.
- [x] Configurable production listen address (`ATOLL_LISTEN_IP`) for loopback-only binding behind a same-host proxy.
- [x] `GET /` plain-text ATProto ASCII banner and API location.
- [x] `GET /xrpc/com.atproto.server.describeServer` with configurable `did`, `availableUserDomains`, invite requirement, blob limit, and optional policy links and operator contact (`ATOLL_PRIVACY_POLICY_URL`, `ATOLL_TERMS_OF_SERVICE_URL`, `ATOLL_CONTACT_EMAIL`).
- [x] Controller test for unauthenticated server description.
- [x] Validated runtime server DID and advertised domain configuration (development defaults to `did:web:localhost`).
- [x] Configured hostname-based server DID document publication with a stable service key.
- [x] XRPC route/NSID validation and method checks before body parsing, including protocol errors for unsupported methods.
- [x] Public-origin XRPC CORS headers and route-aware browser preflight responses.
- [x] Sanitized XRPC JSON responses for framework exceptions, including malformed requests and unexpected server failures.
- [x] Lexicon-based parameter validation for all routed XRPC GET endpoints.
- [x] JSON procedure envelope validation against pinned upstream Lexicons.
- [x] Bounded Lexicon-based subscription parameter validation with protocol error frames.
- [x] Required, optimistic, and skipped record validation for all 19 Bluesky record Lexicons in the pinned upstream revision.
- [x] Configurable local custom record Lexicons with bounded startup validation.
- [x] Exact DNS Lexicon namespace delegation with fresh DID/key/PDS resolution.
- [x] Bounded Lexicon schema retrieval with URI/CID checks and signed repository inclusion proofs.
- [x] Bounded remote record-Lexicon dependency catalogs with schema/reference validation.
- [x] Opt-in network Lexicon integration with record-write validation.

XRPC routing uses the [HTTP API specification](https://atproto.com/specs/xrpc).
Malformed paths return `400 InvalidRequest`; valid but unimplemented method NSIDs
return `501 MethodNotImplemented`. Implemented routes require their declared HTTP
method and otherwise return `405 MethodNotAllowed` with an `Allow` header, before
body parsing or method override. These errors are JSON with `error` and `message`
and are not cached. HTTP HEAD responses omit the body. Percent-encoded route
spellings receive the same checks, including repository subscriptions. Query, JSON procedure envelope, and subscription parameter schemas are validated.
Framework failures rendered by Phoenix also use the XRPC error shape, with
standard HTTP descriptions rather than exception details or stack traces. This
applies in development as well as production; errors still propagate through
Phoenix for server-side reporting. Non-XRPC routes retain their existing error
format. Failures rejected by the HTTP adapter before reaching Phoenix and errors
after a response or WebSocket upgrade has begun are outside this JSON renderer.

Routed GET query parameters are checked against 30 unmodified upstream Lexicons
vendored in `priv/lexicons`, pinned to the revision recorded there with its MIT
license. Validation covers required parameters, string identifier formats and
lengths, integer bounds, booleans, and repeated-key arrays. Controller-specific
checks still enforce cursor semantics, authorization, and local resource limits.
Defaults remain in the existing controllers. Unknown flat parameters are retained
for endpoint-specific handling; `knownValues` is not treated as a closed enum.

Query parsing accepts at most 32 KiB and 256 key/value pairs. Duplicate scalar
parameters, nested form keys, malformed percent escapes, and invalid UTF-8 return
`400 InvalidRequest`. Arrays preserve their order; `getBlocks` also retains its
existing `cids[]` alias. Values remain strings at the controller boundary after
validation. These limits supplement the HTTP server's request-target limits.
Subscriptions use the same bounded decoder and pinned parameter schema. Invalid
parameters, including malformed extension parameters, retain the existing
`InvalidRequest` binary error frame followed by a clean WebSocket close. Cursor
values must be nonnegative safe integers; future-cursor and replay behavior remain
separate stream checks. Real loopback WebSocket tests cover this error framing.

JSON procedure bodies are validated after the existing bounded parsers and
request guards. The pinned procedure schemas enforce required/nullable fields,
JSON primitive types, identifier and datetime formats, and the closed batch-write
union. Invalid envelopes return `400 InvalidRequest` before controller actions.
Unknown extension fields remain available to endpoint-specific checks. Record
objects and PLC operations still require the repository/identity layers' data and
semantic checks; procedure-envelope validation is separate from the record
validation policy described below.
Blob/CAR uploads and bodyless procedures retain their dedicated request handlers.

Browser clients can call XRPC from any origin using explicit authorization
headers. Responses include `Access-Control-Allow-Origin: *`; cookie credentials
are not enabled. Valid OPTIONS preflights for implemented routes return 204 before
body parsing and authentication, permit only the route's declared method, and
advertise a 600-second browser preflight cache lifetime. Actual requests retain
all endpoint authentication and rate limits. Allowed request headers are `Accept`,
`Accept-Language`, `Authorization`, `DPoP`, `Content-Type`, `Atproto-Proxy`, and
`Atproto-Accept-Labelers`. Proxy preflights allow GET or POST without resolving
the destination; actual proxy requests require an active authenticated account.
Clients can read repository revision, content labeler, retry/rate-limit, and
WWW-Authenticate response headers. Unsupported methods or request headers fail
preflight; ordinary OPTIONS requests without preflight headers remain 405.

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

- [x] Merkle Search Tree construction, lookup, insertion, and deletion (streamed rebuilds on mutation).
- [x] Bounded canonical MST builder over sorted entries, integrated with transactional record writes.
- [x] Partial-tree MST editor with canonical split/merge boundaries and inversion tests.
- [x] Deterministic MST serialization and reference root CID compatibility tests.
- [x] P-256 and secp256k1 in-memory key generation, compact low-S signing, and signature verification.
- [x] Version-3 commit signing and verification with expected-DID and schema checks.
- [x] Encrypted PostgreSQL signing-key storage using AES-256-GCM and a separate runtime master key.
- [x] Atomic managed repository creation and internal writes using persisted signing keys.
- [x] Encryption master-key rotation with decryption fallback keys and atomic paginated envelope rewrapping.
- [x] Operator did:web signing-key rotation after external DID-document updates.
- [x] Encrypted pending signing-key custody bound to durable PLC updates, with master-key rewrapping.
- [x] Operator PLC repository signing-key rotation with durable staging and resumable publication.
- [x] Internal encrypted pending custody and atomic installation for PLC directory-authority replacement keys.
- [x] Operator PLC authority-key rotation with preserved priority, durable staging, and resumable completion.
- [x] Signed PLC recovery preflight against verified history, with priority/window checks and displaced-operation reporting.
- [x] Internal durable recovery journal and head-bound submission with verified readback and exact retries.
- [x] Operator recovery of the current local identity from signed forks, with credential revocation and resumable completion.
- [x] Internal atomic repository key restoration with missing, corrupt, or lost-master-key custody.
- [x] Durable encrypted repository-key custody for signed recovery forks, including same-key repair.
- [x] Operator recovery with supplied repository private keys, including unreadable-vault repair and atomic commit publication.
- [x] Internal recovery custody and atomic restoration of PLC authority keys without decrypting old custody.
- [x] Operator authority-only and combined repository/authority key recovery, including old-master-key loss.
- [x] Explicit audited retirement of historical signup key envelopes after completed key reconciliation.
- [x] Recovery with explicitly absent local authority metadata and supplied private custody.
- [x] Operator reconciliation of pending PLC operations explicitly nullified in verified directory history.
- [x] Operator reconciliation of ordinary pending PLC operations retained in active history after compatible directory advancement.
- [x] Operator completion of retained authority-key rotations after compatible directory advancement, without resubmission.
- [x] Operator completion of repository signing-key rotations after compatible directory advancement, with atomic commit and custody publication.
- [x] Operator completion of accepted recoveries after compatible directory advancement, including combined key restoration and credential revocation.
- [x] Operator closure of pending operations absent from verified directory history, including tombstoned or otherwise incompatible directory identities.
- [x] Per-revision signing-key provenance for historical record and block verification.
- [x] Internal atomic repository signing-key replacement with unchanged-tree commits and vault rollback.
- [x] PostgreSQL repository heads and atomic record, tree, and commit updates with optional head compare-and-swap.
- [x] Internal record create, put, delete, and read operations with collection/type checks (not Lexicon validation).
- [x] Public `getRecord` and paginated `listRecords` for repository DIDs or bidirectionally verified handles and current record versions.
- [x] Historical CID versions for record reads, verified against retained signed revisions and the exact record path.
- [x] Bounded search-path verification for historical record-version reads.
- [x] Authenticated `createRecord`, `putRecord`, and `deleteRecord`, with atomic commit/record compare-and-swap.
- [x] Authenticated atomic `applyWrites` batches with ordered results and commit compare-and-swap.
- [x] DID or bidirectionally verified handle addressing for single and batch record writes.
- [x] Local custom record Lexicon loading alongside 19 pinned Bluesky record schemas.
- [x] Authenticated HTTPS/DID/DNS network resolution of supported custom record Lexicons.
- [x] `com.atproto.repo.describeRepo` with resolved DID document, current collections, and bidirectional handle status.
- [x] In-memory CARv1 encoding and decoding with block verification and resource limits.
- [x] Consistent repository CAR export through the internal storage API.
- [x] Internal complete CAR import for existing repositories, with pinned-key verification, expected-head checks, and atomic replacement.
- [x] Authenticated `com.atproto.repo.importRepo` for existing repositories, with bounded uploads and atomic replacement.
- [x] Existing-DID migration provisioning with source-key verification and destination-key signing.
- [x] Internal durable encrypted signing-key reservations, transactional claims, and bounded master-key rewrapping.
- [x] Public `reserveSigningKey` endpoint and DID-bound reserved-key selection during migration account creation.
- [x] Anonymous reserved-key selection through signed `plcOp` migration account creation, with durable publication recovery.
- [x] Chunked repository exports with lazy record-body reads.
- [x] Streamed HTTP imports with private staging and atomic publication.
- [x] Bounded-memory repository metadata traversal.
- [x] Bounded canonical MST traversal and streamed metadata validation for full/incremental HTTP and buffered exports.
- [x] Bounded signed-tree membership verification for current and historical `getBlocks` exports.
- [x] Bounded metadata verification and revision-membership staging for signing-key rotation/recovery.
- [x] Bounded search-path loading for individual signed record proof exports.
- [x] Buffered MST loading through canonical traversal with an explicit retained-metadata budget.
- [x] Buffered snapshot output budgets covering expanded record paths and deduplicated reachable blocks.
- [x] Buffered MST constructor and mutation budgets with preflight record accounting and bounded node emission.
- [x] Streamed complete `describeRepo` collection inventories and budgeted internal collection lists.
- [x] Incremental CARv1 decoding with bounded framing buffers and verified block callbacks.
- [x] Request-scoped private disk staging for incrementally validated CAR blocks.
- [x] Disk-backed staging CID index with bounded lookup memory and collision work.
- [x] Supervised staging cleanup on request exit and configurable per-node concurrency admission.
- [x] Signed repository snapshot validation over staged block readers without collecting record bodies.
- [x] Bounded MST validation and lazy record/CID enumeration for staged import publication.
- [x] Database-side import blob-reference reconciliation with bounded cleanup-job batches.
- [x] Transactional staged snapshot publication with migration re-signing and quota rollback.
- [x] Lazy CARv1 encoding with per-block validation and upstream cancellation cleanup.

`com.atproto.repo.getRecord` returns the current record unless `cid` selects a
retained version, including versions of subsequently deleted records. Historical
reads require an active repository and verify the signed commit and the canonical
MST search path to the exact requested record; an arbitrary stored block or revision
index entry is not sufficient. Candidate revisions stream one at a time without
loading their block arrays. Each search retains at most 2 MiB of encoded path nodes,
with the shared node/depth limits, and reads only the selected record body. Missing
or corrupt selected nodes fail closed; unrelated sibling trees and record bodies
are not audited. The requested record bytes are hash-checked before decoding.
Histories with many candidate revisions can still be expensive. A dedicated version
index and history retention policy remain pending.

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

Create/put return `uri`, `cid`, commit metadata, and `validationStatus`; delete
returns commit metadata. General ATProto data-model, collection/type, blob
ownership, and record-size checks run for every write, regardless of `validate`.
The three record validation modes are:

- Omitted: validate known record schemas; allow unknown schemas.
- `true`: require a known schema and a matching record.
- `false`: skip record schema validation.

Built-in schemas cover all 19 `app.bsky.*` record definitions at the upstream
revision recorded in `priv/lexicons/README.md`, with their reachable input
references. This includes posts, profiles, follows/blocks/likes/reposts, feed
generators, post/thread gates, lists and list membership/blocks/opt-outs, starter
packs, verifications, labeler services, account status, and visibility/notification
declarations. Validation checks required fields, identifier/datetime/URI/language
formats, byte and grapheme limits, arrays, and record keys (TIDs or profile `self`).
Post dependencies include facets, replies, images, video/captions, galleries,
external links, quoted records, and self-labels. Open unions accept future
well-formed variant tags; known variants still require matching fields. Successfully checked records
return `validationStatus: "valid"`; skipped or unknown schemas return `"unknown"`.
Schema mismatch or unavailable required validation returns `400 InvalidRequest`.
Unknown extension fields are retained. The validator does not fetch schemas from
the network. Unknown collections remain unknown unless an operator loads their
schemas as described below. The compiled built-in catalog refreshes when its
schema files are added, removed, or edited. Output schemas and application semantics (such as
verification trust or gate/post ownership relationships) are not validated here. Internal low-level repository APIs and
CAR imports continue to enforce data integrity without applying this write-API
Lexicon policy.

To load custom record schemas, set `ATOLL_LEXICON_DIRECTORY` to a directory of
Lexicon JSON files before starting Atoll:

```sh
ATOLL_LEXICON_DIRECTORY=/path/to/lexicons mix phx.server
```

For example, save this as `com.example.note.json` in that directory:

```json
{
  "lexicon": 1,
  "id": "com.example.note",
  "defs": {
    "main": {
      "type": "record",
      "key": "tid",
      "record": {
        "type": "object",
        "required": ["text"],
        "properties": {
          "text": {"type": "string", "maxLength": 1000}
        }
      }
    }
  }
}
```

These schemas participate in the same create/put/batch validation modes as built-in
records. Helper definitions can reference other configured or bundled definitions.
The loader accepts up to 128 top-level regular `*.json` files, at most 256 KiB each
and 8 MiB combined, with schema nesting limited to 32 levels. Invalid documents,
duplicate JSON keys or NSIDs, unsupported constraints, missing transitive references,
and attempts to replace bundled schemas fail startup. Restart Atoll after changing
this directory; the loaded catalog is a startup snapshot. In Elixir runtime
configuration, the equivalent setting is `config :atoll, :record_lexicons,
Atoll.Lexicon.Loader.load!(directory)`.

Only load schemas you trust as the operator. Local configuration does not authenticate
the NSID owner's authority or expose new XRPC endpoints. To enable network discovery
for unknown collections, set `ATOLL_NETWORK_LEXICONS=true` (default: `false`).
Only literal `true` and `false` are accepted. Network schemas use DNS namespace
delegation and the delegated DID's HTTPS PDS; see Lexicon namespace discovery in [repository.md](repository.md).

Blob schema checks use the declared MIME type and size; the repository independently
requires ownership and matching stored metadata. Profile images allow PNG/JPEG up
to 1,000,000 bytes, while post image limits follow the pinned schemas. This does not
decode media contents or raise the local 5 MiB upload cap, even where a video
schema permits larger files. Language tags use well-formed BCP 47 syntax without
registry lookup or canonicalization. Schema validation does not enforce extra
application semantics such as whether a facet range matches the text's bytes.

Request JSON is limited to 2 MiB; encoded records retain their 1 MB
limit. Writes default to 300 requests per client IP per five minutes using the
configured memory/PostgreSQL/Redis limiter, and responses use `Cache-Control: no-store`.
Set `ATOLL_RECORD_WRITE_RATE_LIMIT` to an integer from 0 to 100000 to change the
record-write budget. Application configuration uses
`config :atoll, :record_write_rate_limit, 300`; the environment variable overrides
this setting only when explicitly supplied. With a positive write budget, the
general XRPC budget also applies independently.

Set `ATOLL_RECORD_WRITE_RATE_LIMIT=0` (or `config :atoll, :record_write_rate_limit, 0`)
to disable HTTP rate throttling entirely for local POST `createRecord`, `putRecord`,
`deleteRecord` and `applyWrites`. These requests bypass both the write bucket and
the aggregate XRPC bucket, without contacting a rate-limit backend. Other routes,
methods and CORS preflights retain their existing budgets. Proxied requests retain
the aggregate XRPC budget, including requests to those record methods. Authentication, DPoP
proof checks, request/record size bounds, schemas, quotas and transaction checks
still apply. Invalid environment values fail startup; invalid application values
reject writes with HTTP 503. This changes policy only when configured; the default
remains 300.

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
The same validation modes apply to each create/update in a batch, with a
per-result validation status. A schema failure rejects the entire batch before
mutation. Deletes and empty batches need no record schema, even with `validate: true`.

### Identity, accounts, and authentication

- [x] P-256 and secp256k1 multikey / `did:key` encoding and decoding with curve-point validation.
- [x] Modern DID-document parsing for expected identity, signing key, HTTPS PDS endpoint, and unverified handle claim.
- [x] Internal HTTPS resolution for `did:plc` and hostname-level `did:web`, with expected-document identity checks.
- [x] Resolver public IPv4/IPv6 address pinning, TLS hostname verification, timeouts, redirect rejection, and 256 KiB response limit.
- [x] Bounded node-local positive DID resolution caching with forced refresh for authorization and identity changes.
- [x] Explicit development/test localhost DID resolution and local server DID publication.
- [x] Offline PLC audit-log verification of genesis, signatures, CID links, recovery windows, and nullification flags.
- [x] Optional verified PLC audit-log resolution with bounded fetching and separate verified-document caching.
- [x] DNS TXT handle resolution with HTTPS fallback, normalization, ambiguity checks, and reserved-domain rejection.
- [x] Internal bidirectional handle verification against the resolved DID document.
- [x] Public `com.atproto.identity.resolveHandle` forward lookup (does not assert bidirectional verification).
- [x] Public `resolveDid` and `resolveIdentity` queries for remote DID documents and verified identity information.
- [x] Distinct `DidDeactivated` errors for PLC directory tombstones and independently verified tombstones, including owner refresh and cache invalidation.
- [x] Handle-based repository reads with bidirectional verification and canonical DID record URIs.
- [x] HTTPS handle-resolution redirects with per-hop address validation and bounded hops.
- [x] Bounded positive handle caching with forced refresh for authorization and identity updates.
- [x] Internal full-session handle-change staging, durable reservations, and verified atomic completion.
- [x] `com.atproto.identity.updateHandle` for hosted/custom handles on modern PLC accounts with a retained authorized rotation key.
- [x] did:web handle reconciliation after an owner updates their hosted DID document.
- [x] Legacy PLC predecessor conversion and signed handle-update staging/completion.
- [x] Operator installation of directory-authorized PLC rotation keys for imported modern/legacy accounts.
- [x] Explicit operator replacement of installed rotation keys with expected-key checks and fresh authority verification.
- [x] Operator signed on-directory rotation-key recovery with supplied private keys.
- [x] Authenticated account activation and deactivation with atomic status events.
- [x] Service-authenticated `createAccount` for migration of an existing DID.
- [x] Authenticated recommended DID credentials for the destination signing key and service.
- [x] Email-authorized account deletion with credential/key removal, blob cleanup, and a deleted-account event.
- [x] Internal PLC operation signing, genesis DID derivation, and predecessor signature checks.
- [x] Internal PLC genesis submission with bounded responses and exact latest-operation confirmation.
- [x] Internal ordinary PLC update submission with predecessor checks and exact-operation retry reconciliation.
- [x] Durable PLC update journal with verified predecessor evidence and separate remote confirmation/local completion.
- [x] Fresh verified audit lookup from the configured PLC directory, with latest-operation consistency checking.
- [x] Durable genesis registration journal and encrypted PLC rotation-key retention.
- [x] Opt-in fresh PLC DID signup under configured server domains, including durable retries and optional recovery keys.
- [x] Hosted handle resolution through `/.well-known/atproto-did`.
- [x] Configurable invite-required signup and migration, limited uses, durable redemption and local operator issuance.
- [x] Separately authenticated HTTP invite issuance, bulk issuance, and disabling by code/account.
- [x] Cursor-paginated admin invite listings and full-session account-owned invite listings.
- [x] Opt-in interval invite allocation with confirmed-email eligibility and an unused-code cap.
- [x] Operator enable/disable controls for future account invite allocation, separate from existing-code revocation.
- [x] Opt-in custom-domain signup through operator DID reservation and verified `createAccount` completion.
- [x] Bounded operator cleanup of expired signup reservations with no recorded PLC submission.
- [x] Opt-in supervised scheduling of bounded unsubmitted-signup cleanup with telemetry.
- [x] Operator resume of exact pending signup registrations without password input or session issuance.
- [x] Opt-in automatic signup retries with database leases, durable delay and activation fencing.
- [x] Operator signup activation from verified directory advancement that preserves local identity and authority.
- [x] Opt-in self-service custom-domain DID reservation during OAuth signup, with bounded pending state, password-bound retries, DNS/HTTPS setup instructions and transactional audit attribution.
- [x] Configurable reserved handle labels (`ATOLL_RESERVED_HANDLES`) refused by self-service signup and handle claims while operator endpoints and existing owners keep them.
- [x] Authenticated signup-queue status reporting live accounts as activated without a queue.
- [x] Documented signup-recovery decision tree mapping each verified directory state to its operator tool; phone verification is an entryway service in the reference deployment, outside a standalone PDS at the pinned revision.
- [x] Internal DID-scoped password credentials with salted Argon2id hashes, bounded input, redacted inspection, and duplicate protection.
- [x] Shared configurable Cloudflare Worker email delivery client.
- [x] Reference Cloudflare email Worker implementation (`ops/email-worker`) on Email Service with bearer auth and KV idempotency.
- [x] `requestPlcOperationSignature` email authorization with atomic single-use challenge consumption.
- [x] Email-authorized `signPlcOperation` with fresh verified predecessor lookup and atomic code consumption.
- [x] `submitPlcOperation` with local key/service/handle constraints, durable retries, and identity-event reconciliation.
- [x] Email confirmation requests and one-use confirmation through the Worker.
- [x] Email updates authorized through the current confirmed address using the Worker.
- [x] Email-based password reset through the Worker with atomic session revocation.
- [x] Internal password session creation, scoped HS256 JWT verification, single-use refresh rotation, and persistent revocation.
- [x] Session JWT signing-key rotation with bounded verification-only fallback keys.
- [x] Public DID/password session creation, refresh, inspection, and revocation endpoints, with bounded requests and per-node rate limits.
- [x] Bidirectionally verified handle/password login with normalized handles and DID-bound sessions.
- [x] Deactivated-account login, refresh, session inspection, repository import, blob upload, missing-blob inventory, and migration-scoped service tokens.
- [x] Email/password login with normalized addresses and locked ownership rechecks.
- [x] Optional email authentication factors for account-password login.
- [x] Opt-in taken-down session scopes and owner-only repository/blob exports.
- [x] App password creation, metadata listing, revocation, restricted sessions, and privileged service delegation.
- [x] Internal ES256 DPoP signature, request, nonce, and access-token binding verification.
- [x] Internal issuer/role-bound OAuth nonce issuance and PostgreSQL-shared atomic DPoP replay rejection.
- [x] Internal bounded client-metadata retrieval and validation of client IDs, redirects, scopes, and authentication declarations.
- [x] Fresh inline/remote confidential-client JWKS retrieval and ES256 public-key validation.
- [x] Internal ES256 JWT client assertions, supplied session-key binding checks, and PostgreSQL-shared assertion replay rejection.
- [x] Internal S256 PKCE verification and pushed authorization admission with bound client/DPoP keys, short-lived references, and 24-hour challenge reuse prevention.
- [x] `POST /oauth/par` with strict form parsing, pre-parser rate limits, DPoP nonce challenges, and browser CORS.
- [x] Internal account-authorized approval/denial with atomic pushed-request consumption and bound authorization-code issuance.
- [x] Internal one-use authorization-code exchange into bound opaque OAuth tokens, with verified reuse revocation.
- [x] HTTP authorization-code token exchange with DPoP nonce challenges, strict forms, rate limits, and CORS.
- [x] Browser pushed-request authorization and explicit consent with optional scope narrowing and account-hint enforcement.
- [x] Internal ES256 WebAuthn registration/assertion verification with a Chrome virtual-authenticator fixture.
- [x] Internal persisted passkey enrollment, one-use ceremonies, user-verified login, inventory and cascading revocation.
- [x] Optional passkey browser enrollment, authentication, management, and password-based recovery.
- [x] OAuth authorization-server and protected-resource discovery metadata with browser CORS.
- [x] OAuth `prompt=create` account-creation flow, including pushed-request validation and browser signup.
- [x] Internal RFC 6238 TOTP verification, authenticator provisioning URIs, and account-bound encrypted secret envelopes.
- [x] Internal persistent TOTP enrollment and confirmation, one-time login codes, database attempt limits, and key rotation.
- [x] Authenticator enrollment/management UI and single-use recovery codes (optional TOTP).
- [x] Client-authenticated OAuth token revocation with DPoP binding, grant-wide invalidation and discovery metadata.
- [x] Internal owner-authenticated OAuth session inventory and per-grant revocation.
- [x] Browser account login, OAuth session inventory/revocation, and logout with encrypted cookies and CSRF protection.
- [x] Persisted OAuth client/DPoP/session bindings and source password-session deletion cascades.
- [x] OAuth refresh rotation with persistent reuse revocation, per-access scope narrowing, and observed confidential-key removal revocation.
- [x] Configurable periodic confidential-client key checks, including idle sessions, with bounded revocation and sweep progress after failures.
- [x] OAuth resource read guard and DPoP `getSession`, with per-access-token email scope enforcement.
- [x] DPoP repository create/put/delete/applyWrites with transitional generic scope and transactional authorization rechecks.
- [x] Granular repository OAuth permissions by collection/action, browser consent, and semantic scope narrowing.
- [x] Granular blob OAuth permissions by MIME type, browser consent, scope narrowing and storage-time checks.
- [x] Granular RPC OAuth permissions for service tokens, with audience/method restrictions, consent and refresh narrowing.
- [x] Granular account permissions for email read/manage and signed repository import.
- [x] Granular OAuth identity permissions for handle changes, PLC signature requests, signing and submission.
- [x] Internal namespace-restricted permission-set expansion and authenticated PostgreSQL resolution cache.
- [x] Permission-set consent, localized descriptions, fixed per-token permission snapshots and refresh recomputation.
- [x] RPC proxy integration with DPoP admission, granular scopes and frozen permission-set grants.
- [x] DPoP blob uploads with transitional generic scope, pre-body proof admission, and transactional authorization rechecks.
- [x] DPoP service-token issuance with current generic/chat scope checks and authorization locks held through signing.
- [x] DPoP authentication on public repository/blob export routes without granting inactive-account export privileges.
- [x] DPoP account-status and missing-blob inventory, scoped to the authenticated account with authorization rechecks.
- [x] DPoP recommended DID credentials and owner-requested identity refresh with base `atproto` scope.
- [x] Explicit OAuth policy for every currently implemented local XRPC route, including public reads and unsupported account/operator grants.
- [x] Localhost virtual public-client metadata, loopback callback matching, and flow integration without metadata network requests.
- [x] OAuth nonce challenges and proof admission for supplied OAuth credentials on all currently implemented local XRPC routes.
- [x] ATProto OAuth authorization and resource server support (discovery, PAR, DPoP token issuance/refresh/revocation, granular scopes and permission sets, browser consent, and resource-route admission above).
- [x] Live-session and repository ownership checks for blob uploads and single/batch record writes.
- [x] Operator Basic authentication for repository/blob exports, including inactive accounts.
- [x] Explicit authorization on every routed account and repository operation: session/app-password checks, OAuth admission, operator Basic credentials, or deliberate public availability.
- [x] Account migration in and out (service-authenticated creation, repository/blob/preference export and import, missing-blob inventory, DID credential recommendation, PLC signature/signing/submission and activation), identity updates, and the signing-key lifecycle including reservation, rotation and operator recovery.
- [x] Authenticated `com.atproto.server.checkAccountStatus` with repository/blob inventory and DID service/key checks.
- [x] Locally served private `app.bsky` actor preferences with namespace replacement, restricted-session personal-details protection and declared-age synthesis.

`Atoll.Accounts.Credentials.create/2` is a trusted internal operation that attaches
a password to an existing repository DID. It never replaces an existing credential.
`verify/2` returns only the DID on success, and the same `:invalid_credentials`
error for missing credentials and incorrect passwords. It proves password possession;
callers must separately check account status and authorization. `createAccount` supports
opt-in fresh PLC signup and service-authorized migration of existing DIDs.

Passwords must be valid UTF-8, 8–1024 bytes, with no trimming or normalization.
Hashes use [argon2_elixir](https://argon2-elixir.hexdocs.pm/Argon2.html) Argon2id
with random salts and the library's default work factors (64 MiB memory, three
iterations, four lanes). Only test configuration reduces the work factors.
Building this dependency requires a C compiler and `make`. Hashes are redacted
from schema inspection, and credential insertion disables query logging.
Email authentication factors are optional. Password recovery
uses the email reset endpoints described in [accounts.md](accounts.md).

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

Session deletion accepts an expired **current** refresh token, matching the
[reference PDS revocation policy](https://github.com/bluesky-social/atproto/blob/main/packages/pds/src/api/com/atproto/server/deleteSession.ts).
Its signature, audience, refresh scope, session owner, token identifier and stored
expiry must still match. Expired tokens cannot authenticate or refresh a session;
this exception only permits deletion. Rotated tokens, access tokens and tokens
for already deleted or cleaned-up sessions remain invalid. Other sessions for the
same account are unaffected, and inactive accounts can still delete sessions.

Session request bodies are limited to 4 KiB before general parsing. Login permits
20 attempts per direct peer IP per five minutes; other session methods share a
300-request limit per peer per five minutes. The limiter retains at most 10000
IP/bucket entries, expires old entries, and denies new keys while at capacity.
It is per-node and resets on restart. Forwarded-IP headers are ignored by default;
configure explicit trusted proxy CIDRs to use the verified proxy chain for client
budgets (see [operations.md](operations.md)). Shared PostgreSQL limits are available; account-level throttling remains pending.
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
repository status. Taken-down accounts can explicitly opt into export-only
sessions as described in [moderation.md](moderation.md); refresh remains blocked during takedown. Suspended
accounts cannot create or refresh sessions. Restrictions are enforced from current database status on each request,
including sessions issued before deactivation. Sessions survive process restarts.
Changing the signing key without a verification fallback invalidates existing tokens.
Session-key overlap is supported as described in [keys.md](keys.md). Write handlers recheck authorization inside the
write transaction; token verification alone is not write permission.

Expired session rows can be removed with `mix atoll.sessions.prune --limit 500`
(use `MIX_ENV=prod` with production configuration). Each invocation deletes one
batch of at most 1–1000 rows, oldest expiry first, and reports only the deleted
count. Rows with expiration after the batch starts are retained, and rows locked
by another transaction are skipped. Repeat or schedule the command to clear a
backlog; zero deleted rows can mean remaining expired rows are locked. Cleanup
does not revoke live sessions or alter refresh-token rotation. The internal
`Atoll.Accounts.SessionCleanup.prune_expired/1` API supports release maintenance.
Opt-in automatic cleanup is available with `ATOLL_ACCOUNT_CLEANUP_ENABLED=true`
(see authentication-state cleanup in [operations.md](operations.md)).
Successful manual batches, including no-ops, atomically append an
`atoll.sessions.prune` audit entry. Scheduled deletions use actor `worker`; idle
scheduled checks create no audit rows. Entries contain the limit, expiration
cutoff, and deletion count without session IDs, account identifiers, token hashes,
or credentials. Audit insertion failure rolls back session deletion. Cleanup
acquires the global event lock before session locks, with the existing one-second
lock and five-second statement deadlines. View entries using
`mix atoll.moderation.history` without a DID filter.

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
checks use the configured PLC resolution policy, including audit verification when
enabled. Authorization is rechecked under the repository
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
- [x] Lexicon MIME and size constraints for supported post/profile blob fields.
- [x] Bounded signature-based MIME detection for common binary media uploads.
- [x] MIME and size constraints for blobs in configured custom record Lexicons.
- [x] Opt-in bounded structural image validation with dimension budgets and declared/detected type coherence (pixel data is never decoded or transformed).
- [x] Atomic nested record-reference tracking, ownership/metadata checks on writes, and withdrawal when the last reference is removed.
- [x] Public `com.atproto.sync.getBlob` and paginated `listBlobs`, with `since` filtering, repository status checks, and restrictive content headers.
- [x] Authenticated `com.atproto.repo.listMissingBlobs` with account-scoped CID pagination and referencing record URIs.
- [x] Internal staged-blob expiration with a 24-hour default grace period and a one-hour minimum.
- [x] Bounded operator staged-blob expiration command with atomic ownership/queue audit records and worker attribution.
- [x] Durable cleanup queue for withdrawn/expired blob ownership, shared-owner checks, PostgreSQL/S3 deletion, and retryable S3 failures.
- [x] Audited operator blob collection with durable batch intent, transactional item outcomes, and explicit partial-progress handling.
- [x] Opt-in supervised cleanup scheduling with bounded batches, task deadlines, failure recovery, and outcome telemetry.
- [x] Transactional per-account blob byte and object-count quotas across both storage backends.
- [x] Read-only paginated S3 inventory of owned, queued, untracked, and unrecognized objects.

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
Media types are syntax-checked by default; the opt-in structural validation
mode ([operations.md](operations.md)) additionally parses supported image containers. Bytes are never
transformed.

### Blob storage configuration

`ATOLL_BLOB_STORAGE` defaults to `postgres`. Set it to `s3` to store new blob
bytes in an S3-compatible bucket while retaining ownership, MIME type, size,
and backend metadata in PostgreSQL. Repository commits and MST blocks remain
in PostgreSQL. S3 uses signed, path-style requests and fixed object keys
`blobs/<base32-CID>`; the bucket must already exist. Keep it private unless
deliberately exposing objects through a public bucket domain.

| Variable | Purpose |
| --- | --- |
| `ATOLL_S3_ENDPOINT` | Service origin, such as `https://s3.us-east-1.amazonaws.com` or `http://localhost:9000` for local MinIO |
| `ATOLL_S3_PUBLIC_DOMAIN` | Optional public bucket domain, e.g. `cdn.rocksky.social` or `https://cdn.rocksky.social`; no bucket name or path |
| `ATOLL_S3_BUCKET` | Existing bucket name |
| `ATOLL_S3_REGION` | Signing region; defaults to `us-east-1` |
| `ATOLL_S3_ACCESS_KEY_ID` | Access key with object PUT/GET/DELETE permission |
| `ATOLL_S3_SECRET_ACCESS_KEY` | Secret key, supplied outside version control |
| `ATOLL_S3_SESSION_TOKEN` | Optional temporary-credential token |

When configured, local profile and post image URLs for available S3 blobs use
`https://<public-domain>/blobs/<base32-CID>`. An explicit
`ATOLL_IMAGE_CDN_URL_PATTERN` takes precedence. PostgreSQL blobs and deployments
without the public domain retain the PDS `getBlob` URL. Signed S3 operations and
the `getBlob` authorization and byte-verification path are unchanged. The domain
must map directly to the bucket root and serve the correct content type.
Direct CDN links remain subject to the CDN's access and cache policy; withdrawing
a reference or taking down an account does not revoke a previously issued public
link, so public-object removal/cache purging must be handled at the CDN too.

Trusted internal callers can use:

```elixir
{:ok, blob} = Atoll.Blobs.stage(did, bytes, "image/png", content_length: byte_size(bytes))
{:ok, cid} = Atoll.CID.from_base32(blob["ref"]["$link"])
Atoll.Blobs.get_staged(did, cid)
```

The first stored MIME type for an account/CID is retained on repeat staging;
declarations must be concrete `type/subtype` values without parameters. Bytes
are never transformed. MIME declarations are normalized, then up to the first 512 bytes are inspected
for known binary signatures before new metadata is stored. Recognized PNG, JPEG,
GIF, WebP, BMP, ICO/CUR, ID3-tagged MP3, Ogg, MIDI, AIFF, WAVE, AVI, and MP4
signatures override the declaration; other content keeps the normalized declared
type. MP4 detection requires a complete initial `ftyp` box within that prefix and
an aligned `mp4` brand. The signature tables follow the
[WHATWG MIME Sniffing Standard](https://mimesniff.spec.whatwg.org/); this is not a
complete browser sniffing implementation (for example, WebM and untagged MP3 are
not detected). HTML/SVG/text are not inferred from content.

Clients must use the returned descriptor's MIME type when creating records.
Detection preserves bytes, CID, and size, works with PostgreSQL and S3, and keeps
already-stored per-account/CID metadata stable on repeat uploads. Existing blobs
are not reclassified. Signature matches do not prove that a file is decodable or
safe; full media decoding and malware scanning are not implemented.
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

The operator CLI expires one page of staging ownership:

```sh
mix atoll.blobs.expire --limit 100 --grace-seconds 86400
```

Its limit is 1–1000 and grace is 3600–31536000 seconds. It prints the expired count
as JSON and queues byte cleanup without performing collection. Expiration records
`atoll.blobs.expire` in the same transaction as ownership removal and cleanup
enqueueing, including the cutoff, bounded DID/CID/backend list and count, without
blob contents. Audit failure rolls back the entire expiration page. Lock and SQL
statement deadlines are one and five seconds respectively. Read this server-wide
history with `mix atoll.moderation.history` without a DID filter.

Internal expiration defaults to actor `operator`, including no-op audit entries.
The scheduler explicitly uses actor `worker` and records only nonempty expiration
pages. Actor labels are trusted internal metadata, not an authorization interface.

Expiration removes only old, unreferenced ownership metadata and queues its bytes.
Re-uploading renews the staging grace period. Collection rechecks all accounts for
ownership of that backend/CID before deleting bytes, and leaves failed S3 deletes
queued for retry. Run collection outside any caller transaction: S3 deletion cannot
be rolled back. Collection does not discover objects orphaned before this queue
was introduced. Versioned S3 buckets retain
older object versions behind delete markers; bucket lifecycle/version cleanup is
separate from this collector.

For queued byte cleanup, run one operator batch:

```sh
mix atoll.blobs.collect --limit 10
```

The command accepts 1–1000 jobs (default 10), prints deleted/retained/failed/skipped
counts as JSON, and exits unsuccessfully if any deletion failed. Collection now
records a server-wide `atoll.blobs.collect` attempt before processing, per-item
outcomes in the same transactions as local queue changes, and a final batch
summary. Records contain CID/backend identifiers, fixed outcome labels and a
link to the attempt ID; they exclude blob bytes, credentials and S3 error bodies.
Operator no-op batches are recorded. The scheduler supplies actor `worker` and
does not record empty collection batches.

An audit failure before batch processing prevents deletion. Each PostgreSQL byte
deletion rolls back with its item audit if that transaction fails. S3 deletion
cannot roll back: a failure after a remote delete may leave the queue job for a
later idempotent retry, with only the batch intent recorded. Earlier item
transactions remain committed if a later item fails. An attempt without a final
summary therefore means incomplete or uncertain processing, not that nothing
happened. Inspect `mix atoll.moderation.history` and queue state before retrying.
Collection keeps the shared write lock during each ownership check and S3 delete;
audit SQL uses one-second lock and five-second statement deadlines. Batch size
does not imply a single all-or-nothing transaction or a total wall-clock deadline.

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

- [x] Full repository export via `com.atproto.sync.getRepo` (chunked CAR, no aggregate archive-size cap).
- [x] Incremental repository exports using `since`, backed by per-repository revision block sets; unknown revisions return a full snapshot.
- [x] Transactional per-repository block reference counts for quota/status inventory and garbage-collection lookups.
- [x] Bounded operator revision-history compaction preserving current heads and retained replay dependencies.
- [x] `com.atproto.sync.listReposByCollection` with indexed collection lookup, distinct active DIDs and exclusive pagination.
- [x] `getLatestCommit`, `getRepoStatus`, and paginated `listRepos` sync endpoints with persistent repository status.
- [x] Deprecated `com.atproto.sync.getHead` and `getCheckout` for older consumers, sharing current availability checks and export authorization.
- [x] `com.atproto.sync.getRecord` compact signed existence and absence proofs.
- [x] Bounded verification of partial MST search paths and signed record CAR inclusion proofs.
- [x] `com.atproto.sync.getBlocks` for current and retained historical repository blocks (1–100 CIDs; repeated `cids` query parameters).
- [x] Export consistency checks against the signed commit, tree root, and revision.
- [x] Internal deactivation, suspension, takedown, and reactivation; inactive repositories reject public reads, exports, and ordinary record writes. Authenticated migration imports/uploads allow deactivated accounts only.
- [x] Historical block retrieval with signed-commit and canonical-tree membership checks, including deleted records and prior MST nodes.
- [x] Internal durable event sequencing and cursor replay, recorded atomically with repository creation, writes, imports, and status changes.
- [x] Bounded operator event retention with a durable replay floor and `OutdatedCursor` stream notices.
- [x] Opt-in supervised event-retention scheduling with bounded batches, timeouts, and outcome telemetry.
- [x] Strictly ordered, gapless-at-read event sequencing through a single PostgreSQL advisory lock — the same single-sequencer model as the reference PDS, chosen deliberately so sequence allocation and commit visibility share one order; horizontal write sharding is out of scope.
- [x] `com.atproto.sync.subscribeRepos` binary WebSocket stream with exclusive resume cursors, live delivery, and account status events.
- [x] Configurable per-node and per-IP live firehose quotas with monitored ownership, pending-upgrade expiry and fail-closed restarts.
- [x] Invalid/future cursor errors, bounded replay backlog, idle pings, and current-availability filtering for repository data.
- [x] Wire-format commit, sync, account, and identity event encoding, plus CBOR stream/error framing.
- [x] Commit CARs with compact MST boundaries, changed records, prior roots, and operation metadata; oversized commits fall back to commit-only sync messages.
- [x] Compact inductive commit proofs with operation-state checks and reverse reconstruction of the previous root.
- [x] Internal `Atoll.Identity.Updates.refresh/2`: resolves hosted identities, verifies claimed handles, and atomically records changed observations with durable identity events.
- [x] Opt-in supervised identity refresh scheduling, with one task at a time, timeouts, sweep retries, and outcome telemetry.
- [x] Owner-authenticated identity refresh with fresh DID resolution and atomic observation events.
- [x] PostgreSQL-coordinated automatic identity refreshes with expiring leases and publication fencing.
- [x] The complete `com.atproto.identity` endpoint surface at the pinned upstream revision: resolution, recommended credentials, handle updates, owner refresh, and PLC signature request/signing/submission.
- [x] Configurable operator crawl announcements to relay `com.atproto.sync.requestCrawl` endpoints.
- [x] Durable operator crawl attempt/completion audit records, with no relay request if attempt recording fails.
- [x] Opt-in supervised periodic crawl announcements to configured relays.
- [x] Configuration-driven relay announcements matching the reference implementation's `PDS_CRAWLERS` model (the protocol defines no relay discovery), with opt-in interoperability suites for the official client, OAuth SDK, and firehose consumer.
- [x] `com.atproto.server.getServiceAuth` issues short-lived account-signed service JWTs.
- [x] Internal incoming account service-JWT verification with exact audience/method checks and persistent replay protection.
- [x] Service-authenticated migration account creation.
- [x] Internal proxy service resolution and bounded, public-IP-pinned HTTPS transport.
- [x] Authenticated request proxying to AppViews and other services, with an optional default AppView.
- [x] Phase-1 service-auth audiences: proxied grants are checked against the `did#service` form while outbound JWTs carry the bare DID the receiving services verify.
- [x] `app.bsky.feed.getFeed` proxying that resolves the feed's published generator record and mints `getFeedSkeleton` tokens for the generator DID, with dual RPC grant checks for OAuth callers.
- [x] Push-notification registration whose token audience is the body's `serviceDid`, delivered to the AppView or directly to the named notification service.
- [x] Read-after-write munging of stale AppView responses: fresh local posts, profile edits and unindexed own threads spliced into the six reference-munged read methods, with upstream-lag reporting and bounded local reads.
- [x] Default moderation-report and ozone method routing to configured moderation/report services.

The internal `Atoll.Proxy.Target` resolver requires a concrete DID with a service
fragment and exactly one matching service entry in the resolved DID document.
Relative and absolute service identifiers are accepted; duplicate entries are
rejected. The endpoint must be an HTTPS origin without credentials, query,
fragment or path prefix. Its independently checked public IP address is pinned
for the outbound connection while preserving the hostname for TLS and HTTP.

`Atoll.Proxy.Transport` preserves repeated query parameters and raw POST bytes,
accepts a separately minted service JWT, and filters request/response headers.
Caller access tokens, DPoP proofs and cookies are not forwarded. Redirects,
compressed responses and oversized responses are rejected. Request bodies are
bounded to 2 MiB, query strings to 8 KiB and streamed responses to 8 MiB, with
connection and request deadlines.

Clients can send GET or POST requests to a canonical `/xrpc/<NSID>` path with
`Atproto-Proxy: did:web:service.example.com#service_name`. This explicitly selects
proxying even when the method also exists locally. Duplicate/malformed target
headers, encoded path aliases and other HTTP methods are rejected. No default
AppView is selected unless configured:

```elixir
config :atoll, :appview_proxy, "did:web:appview.example.com#bsky_appview"
```

`ATOLL_APPVIEW_PROXY` overrides this setting when supplied; an empty value disables
the default. Malformed environment values fail startup. The default applies only
to unknown `app.bsky.*` methods without an explicit proxy header. Existing local
routes remain local. All targets resolve through their DID service entry; the
default is a service identity, not an arbitrary endpoint URL.

Both legacy access sessions and DPoP OAuth require an active account. App-password
restrictions and protected service-auth methods still apply. OAuth accepts an
RPC permission matching the full service audience and exact NSID, including
permissions expanded from the access token's frozen permission-set snapshot,
or an applicable transitional generic/chat grant with its existing restrictions. Repository
permissions alone never authorize remote calls. Proof admission and the initial
scope check precede body reads and service resolution; a failed preparation still
consumes an admitted proof. The current account, source session, OAuth grant and
access token are rechecked under locks before signing. Resolution and outbound
HTTP run outside database transactions.

Every forwarded request receives a fresh account-signed JWT with the full
`DID#service` audience, exact `lxm`, random `jti` and a 60-second lifetime. Local
session credentials are never forwarded. Revocation detected before signing
prevents the request; a JWT already sent cannot be recalled and may remain valid
until expiry. Receivers must enforce its audience, method and validity themselves.
The aggregate XRPC rate limit also applies to proxied record writes when local
record throttling is disabled. Upstream 2xx/4xx/5xx status and body are preserved
within the transport bounds; resolution/invalid-response failures return 502 and
upstream timeouts return 504. Replies use `no-store`, `nosniff` and a sandbox CSP;
remote cookies, redirects and CORS/authentication headers are not relayed.

Tests exercise signed claims, legacy/app/OAuth authorization, grant revocation and
narrowing during resolution, permission-set cache eviction, raw request bodies,
proof replay, rate limits, preflights, response filtering and transport bounds.
External AppView/client interoperability remains a separate pending test suite.
The protocol behavior follows the [service proxy specification](https://atproto.com/specs/xrpc#service-proxying).

Historical `getBlocks` reads are limited to active repositories and return only
requested blocks in a rootless CAR. Deleted record bytes remain publicly retrievable
while their signed revisions are retained. Candidate revisions are selected by
their block indexes, then their commits and canonical trees are verified before
granting access; shared storage or index membership alone is insufficient. A
missing or foreign CID rejects the whole request. Current and historical membership
verification uses bounded canonical MST traversal, retaining only pending branches
and at most 100 requested CIDs. Revision block arrays stay in PostgreSQL; candidate
rows stream one at a time with only commit/revision/signing-key metadata. Every
selected tree is exhausted even after all requested CIDs have been found, so missing
or corrupt nodes reject the request before any CAR is returned. Only requested
record bodies are read and hash-checked; unrelated historical record-body damage
does not prevent serving authenticated blocks. Current metadata is checked against
the streamed record index. Work still grows with the size and number of candidate
trees, and the returned CAR remains buffered within its existing archive limit.

`GET /xrpc/com.atproto.server.getServiceAuth` normally requires an active account's access
token (legacy JWT or DPoP OAuth) and a stored repository signing key. Supply `aud` as a DID or DID with a
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
Atoll does not accept incoming service JWTs as local access tokens. Outbound proxy
requests use account-signed service JWTs as described above.
With a legacy full-account session, deactivated accounts can request only the `com.atproto.server.createAccount`
method for migration. Taken-down scopes cannot request service tokens. App-password delegation requires an explicit method; standard app passwords cannot delegate chat methods.

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
The opt-in authentication-state cleanup worker schedules replay-marker pruning.
Migration account creation uses this verifier, which
uses the configured PLC resolution policy: directory HTTPS trust by default, or
independent audit verification when enabled.

`GET /xrpc/com.atproto.sync.listReposByCollection?collection=com.example.record`
lists distinct active hosted DIDs with at least one current record in that exact
collection. The response contains `repos: [{did: "..."}]`; the default page size
is 500 and `limit` accepts 1–2000, following the vendored
[upstream Lexicon](https://github.com/bluesky-social/atproto/blob/7a857989751ae31518509d69ab7194a922064f3d/lexicons/com/atproto/sync/listReposByCollection.json).
The optional cursor is the last returned DID, ordered bytewise and exclusive.
A response includes a cursor only when another matching DID exists. Continue with
the same collection; pagination observes current committed state, not a snapshot
across requests. A valid collection with no records returns an empty list; a missing or malformed
collection is rejected.

This public discovery query excludes deactivated, suspended and taken-down
accounts. Supplied OAuth credentials still undergo normal public-read proof and
grant validation; owner credentials do not broaden the result. Record takedowns
retain signed sync data and therefore do not remove collection membership.
Membership derives from current repository records, so writes, deletions and
imports need no separate asynchronous inventory update. A database expression
index on collection and bytewise DID supports lookup and pagination. Run the new
migration before serving the route; creating this index takes the usual PostgreSQL
index-build lock on record writes, so schedule it appropriately for large servers.

For local development, connect to
`ws://localhost:4000/xrpc/com.atproto.sync.subscribeRepos?cursor=0`.
Omit `cursor` to start at the current stream position; otherwise pass the last
received sequence number to replay later events. Messages are binary frames with
two concatenated CBOR objects (header and body), not JSON or Phoenix channels.
Idle connections poll PostgreSQL every 500 ms and send a ping every 15 seconds.
Connections more than 10,000 persisted events behind receive `ConsumerTooSlow`
and close; sequence gaps do not count toward this limit. Replay skips commit and
sync data for currently inactive repositories, but still emits account and identity events.
Internet deployment requires WSS termination; federation interoperability testing
remains pending.

Firehose admission defaults to 1024 simultaneous connections per node and 16 per
client IP. Configure `:firehose_max_connections` and
`:firehose_max_connections_per_ip`, or set `ATOLL_FIREHOSE_MAX_CONNECTIONS` and
`ATOLL_FIREHOSE_MAX_CONNECTIONS_PER_IP`. Each accepts 1–100000; unset environment
variables preserve application configuration, invalid environment values reject
startup, and invalid application values fail admission with HTTP 503. Limits are
checked on each new admission; lowering them does not evict existing connections.
These are live-connection quotas, separate from XRPC request budgets. They remain
node-local regardless of the selected memory/PostgreSQL/Redis request-rate backend.
Scale the node limits to the deployment and its load balancer.

Pending upgrades count toward both limits and expire after 30 seconds if the
socket never claims them. Failed handshakes release their slots, and process
monitors reclaim slots after disconnects or crashes. At capacity, the handshake
returns HTTP 429 `RateLimitExceeded` with `Retry-After: 1`; retry with backoff.
Quota-manager unavailability returns HTTP 503. Active sockets monitor the manager
and close with service-restart semantics if it exits, rather than continuing
without tracked capacity. A stale or expired upgrade reservation closes with
WebSocket code 1013. Peer identity uses the existing trusted-proxy IP policy;
untrusted forwarding headers do not grant a different quota. These controls do
not replace TCP connection limits or WSS termination at the ingress.

Identity refreshes announce changes in the resolved handle, signing key, or PDS
endpoint. Unverified handles are emitted as `handle.invalid`; failed DID lookups
preserve the previous observation. Refreshes do not rotate the repository's
pinned signing key or move accounts.

Set `ATOLL_IDENTITY_REFRESH_ENABLED=true` before starting Atoll to enable automatic
refreshes. The worker starts after one second, waits one second between identities,
and waits five minutes after each complete sweep. Each refresh has a 20-second
deadline; failures are retried on a later sweep. All hosted identities, including
inactive ones, are visited in DID order. Workers coordinate through PostgreSQL
leases, so automatic refresh can run on multiple instances sharing the database.
Restarts begin a new sweep and honor existing leases and cooldowns. Unchanged
observations do not produce duplicate events. The
`[:atoll, :identity, :refresh]` telemetry event reports a count and `published`,
`unchanged`, `skipped`, `failed`, or `timeout` outcome.

### Operations

- [x] `mix precommit` checks compilation warnings, unused dependency locks, formatting, and tests.
- [x] GitHub Actions runs checks and the Docker MinIO integration suite on every push (also available manually).
- [x] Session, blob-upload, and record-write rate limits and bounded request bodies.
- [x] Configurable record-write budget with an explicit zero setting to disable write throttling entirely.
- [x] Configurable general XRPC request budget before parsing, in addition to specialized rate limits.
- [x] Explicit trusted-proxy CIDRs and bounded client-IP extraction for all request rate limits.
- [x] Optional PostgreSQL-shared request budgets across nodes, with bounded storage and fail-closed errors.
- [x] Optional Redis-shared request budgets; in-memory remains the default.
- [x] Operator account status reads, takedowns, restoration, and deactivation.
- [x] Account-scoped blob takedowns across PostgreSQL/S3 serving, uploads, references, and cleanup.
- [x] Operator record takedowns for JSON record reads and listings (signed sync data remains available).
- [x] Transactional history of successful account/record/blob subject-status decisions, with bounded operator export.
- [x] Operator account inspection, singly and in bounded batches, with private metadata and invite histories.
- [x] Operator account search with bounded DID pagination and exact email filtering.
- [x] Audited operator PLC directory signing-key updates with durable exact retries and identity notifications, separate from local private custody.
- [x] Audited operator handle updates using verified PLC publication or did:web reconciliation, including inactive accounts.
- [x] Audited operator email correction with invalidation of old email challenges.
- [x] Audited operator password replacement with session, app-password, and pending-code revocation.
- [x] Transactional audit history for account invite enable/disable decisions and private reason changes.
- [x] Transactional audit history for API and CLI operator invite-code issuance and API revocation, without redeemable codes.
- [x] Audited operator account deletion with durable shared-safe blob cleanup.
- [x] Operator account messages through the configurable email Worker, with attempt/outcome history.
- [x] Atomic operator audit entries for PLC key installation, replacement, and unchanged retries, without private-key material.
- [x] The complete `com.atproto.admin` endpoint surface at the pinned upstream revision, with transactional audit history for every mutating operator action.
- [x] Production boot requiring the database, cookie, key-encryption and session secrets, compile-time HSTS/HTTPS enforcement behind a TLS proxy, release migrations, and a deployment guide covering reverse-proxy WebSockets and signing-key custody.
- [x] Logical PostgreSQL archive/restore helper with checksums, empty-target protection, and disposable-database integration checks.
- [x] Disposable full-schema PostgreSQL restore drill covering signed repositories, encrypted custody, sessions, blobs, private preferences, audit history and replay boundaries.
- [x] Offline S3 blob archives with CID verification, empty-prefix restoration, and a real MinIO round trip.
- [x] Combined PostgreSQL/MinIO restore drill for published and staged blobs, retained credentials, signed repositories and post-restore publication.
- [x] Paired offline recovery-set wrapper binding database/S3 archives, deployment revision and a nonsecret external-keyring reference.
- [x] Recovery-set checks for every database-owned S3 blob's archive membership and size, including staged blobs and mixed storage.
- [x] Recovery-set verification of PostgreSQL-owned blob presence, byte size and CID digest, with missing/corrupt/mismatched-size restore-drill cases.
- [x] PostgreSQL and combined S3 restore drills for enrolled TOTP, encrypted factor custody, used-step/recovery-code preservation, and fresh second-factor logins.
- [x] Passkey restore drills covering public credentials, user handles, RP binding, retained counters/sessions, consumed and expired challenges, and fresh signed logins.
- [x] Read-only maintenance mode refusing every mutation and OAuth-credentialed read before parsing, with background writers kept stopped for consistent backups.
- [x] Paired database/S3 recovery sets with ownership coverage checks, restore drills spanning custody, credentials, second factors, preferences, blobs and replay state, and the documented backup/restore workflow in `ops/backup`.
- [x] `GET /health/ready` database connectivity readiness with bounded queries and outcome telemetry.
- [x] Opt-in supervised cleanup of expired sessions and service-token replay markers, with bounded batches and outcome telemetry.
- [x] Opt-in operator-authenticated Prometheus endpoint with fixed-cardinality HTTP, database, readiness, worker and VM metrics.
- [x] Firehose admission counters, bounded live-capacity inventory, and sustained-capacity/stale-inventory alerts.
- [x] Fixed-bucket HTTP, database and pool-wait latency histograms, percentile query guidance and Prometheus exposition validation.
- [x] Baseline Prometheus alert rules and operator runbook, with firing/recovery/counter-reset tests in CI.
- [x] Scheduler progress-deadline gauges for all eight background workers, with an overdue-progress alert and rule tests.
- [x] Configured-worker expectation and process-presence gauges with missing-worker alerts independent of prior heartbeat observations.
- [x] Prometheus alerts for sustained database pool wait and total query latency, with volume floors, recovery and counter-reset tests.
- [x] Cached per-backend blob cleanup backlog inventory, bounded database polling, and stale-inventory/aged-backlog alerts.
- [x] Operational monitoring and alerting: fixed-cardinality HTTP/database/readiness/worker/VM metrics, latency histograms, firehose and cleanup-backlog inventories, twelve alert rules with CI-tested firing/recovery, and an operator runbook in `ops/prometheus`.
- [x] Offline MST and compact-proof interoperability against pinned `@atproto/repo` 0.8.10 fixtures.
- [x] Opt-in live HTTP integration with the official ATProto client, including signed repository and record-proof verification.
- [x] Opt-in official OAuth SDK integration covering discovery, PAR, narrowed granular repository/blob/email/RPC consent, DPoP resources, refresh and source-session revocation.
- [x] Upstream WebSocket firehose decoding, signed commit application, live delivery, cursor resumption and error-frame integration tests.
- [x] End-to-end compatibility suites against pinned official implementations: the `@atproto/api` client (sessions, records, blobs, preferences), the official OAuth client SDK, the upstream firehose consumer, and `@atproto/repo` proof fixtures. Live-network federation against public relays and AppViews remains an operator deployment check, not a repository test.
