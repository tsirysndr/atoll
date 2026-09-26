# Atoll
[![ci](https://github.com/tsirysndr/atoll/actions/workflows/test.yml/badge.svg)](https://github.com/tsirysndr/atoll/actions/workflows/test.yml)

An AT Protocol Personal Data Server (PDS), built with Elixir, Phoenix, and PostgreSQL. Work in progress.

Atoll provides account hosting, signed repositories, blob storage, and repository subscriptions. Federation interoperability and other production requirements remain under development; see the checklist below.

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
- [x] XRPC route/NSID validation and method checks before body parsing, including protocol errors for unsupported methods.
- [x] Public-origin XRPC CORS headers and route-aware browser preflight responses.
- [x] Sanitized XRPC JSON responses for framework exceptions, including malformed requests and unexpected server failures.
- [x] Lexicon-based parameter validation for all routed XRPC GET endpoints.
- [x] JSON procedure envelope validation against pinned upstream Lexicons.
- [x] Bounded Lexicon-based subscription parameter validation with protocol error frames.
- [x] Required, optimistic, and skipped record validation for all 19 Bluesky record Lexicons in the pinned upstream revision.
- [x] Configurable local custom record Lexicons with bounded startup validation.
- [ ] Authenticated Lexicon discovery/resolution.

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

Routed GET query parameters are checked against 26 unmodified upstream Lexicons
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
`Accept-Language`, `Authorization`, `Content-Type`, `Atproto-Proxy`, and
`Atproto-Accept-Labelers` (the latter two do not imply proxy implementation).
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

- [x] Merkle Search Tree construction, lookup, insertion, and deletion (rebuilds on mutation).
- [x] Deterministic MST serialization and reference root CID compatibility tests.
- [x] P-256 and secp256k1 in-memory key generation, compact low-S signing, and signature verification.
- [x] Version-3 commit signing and verification with expected-DID and schema checks.
- [x] Encrypted PostgreSQL signing-key storage using AES-256-GCM and a separate runtime master key.
- [x] Atomic managed repository creation and internal writes using persisted signing keys.
- [x] Encryption master-key rotation with decryption fallback keys and atomic paginated envelope rewrapping.
- [ ] Signing-key rotation and recovery workflows.
- [x] PostgreSQL repository heads and atomic record, tree, and commit updates with optional head compare-and-swap.
- [x] Internal record create, put, delete, and read operations with collection/type checks (not Lexicon validation).
- [x] Public `getRecord` and paginated `listRecords` for repository DIDs or bidirectionally verified handles and current record versions.
- [x] Historical CID versions for record reads, verified against retained signed revisions and the exact record path.
- [x] Authenticated `createRecord`, `putRecord`, and `deleteRecord`, with atomic commit/record compare-and-swap.
- [x] Authenticated atomic `applyWrites` batches with ordered results and commit compare-and-swap.
- [x] DID or bidirectionally verified handle addressing for single and batch record writes.
- [x] Local custom record Lexicon loading alongside 19 pinned Bluesky record schemas.
- [ ] Authenticated network resolution of custom record Lexicons.
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
the NSID owner's authority or expose new XRPC endpoints. Authenticated network
Lexicon discovery remains unimplemented.

Blob schema checks use the declared MIME type and size; the repository independently
requires ownership and matching stored metadata. Profile images allow PNG/JPEG up
to 1,000,000 bytes, while post image limits follow the pinned schemas. This does not
decode media contents or raise the local 5 MiB upload cap, even where a video
schema permits larger files. Language tags use well-formed BCP 47 syntax without
registry lookup or canonicalization. Schema validation does not enforce extra
application semantics such as whether a facet range matches the text's bytes.

Request JSON is limited to 2 MiB; encoded records retain their 1 MB
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
- [x] Handle-based repository reads with bidirectional verification and canonical DID record URIs.
- [x] HTTPS handle-resolution redirects with per-hop address validation and bounded hops.
- [x] Bounded positive handle caching with forced refresh for authorization and identity updates.
- [ ] Handle updates.
- [x] Authenticated account activation and deactivation with atomic status events.
- [x] Service-authenticated `createAccount` for migration of an existing DID.
- [x] Authenticated recommended DID credentials for the destination signing key and service.
- [x] Email-authorized account deletion with credential/key removal, blob cleanup, and a deleted-account event.
- [x] Internal PLC operation signing, genesis DID derivation, and predecessor signature checks.
- [x] Internal PLC genesis submission with bounded responses and exact latest-operation confirmation.
- [x] Internal ordinary PLC update submission with predecessor checks and exact-operation retry reconciliation.
- [x] Durable genesis registration journal and encrypted PLC rotation-key retention.
- [x] Opt-in fresh PLC DID signup under configured server domains, including durable retries and optional recovery keys.
- [x] Hosted handle resolution through `/.well-known/atproto-did`.
- [x] Configurable invite-required signup and migration, limited uses, durable redemption and local operator issuance.
- [x] Separately authenticated HTTP invite issuance, bulk issuance, and disabling by code/account.
- [x] Cursor-paginated admin invite listings and full-session account-owned invite listings.
- [x] Opt-in interval invite allocation with confirmed-email eligibility and an unused-code cap.
- [x] Operator enable/disable controls for future account invite allocation, separate from existing-code revocation.
- [ ] Custom-domain signup, phone verification, and abandoned signup reservation cleanup.
- [x] Internal DID-scoped password credentials with salted Argon2id hashes, bounded input, redacted inspection, and duplicate protection.
- [x] Shared configurable Cloudflare Worker email delivery client.
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
- [ ] ATProto OAuth authorization and resource server support.
- [x] Live-session and repository ownership checks for blob uploads and single/batch record writes.
- [x] Operator Basic authentication for repository/blob exports, including inactive accounts.
- [ ] Authorization for remaining account and repository operations.
- [ ] Account migration, identity updates, and signing-key lifecycle.
- [x] Authenticated `com.atproto.server.checkAccountStatus` with repository/blob inventory and DID service/key checks.

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
It is per-node and resets on restart. Forwarded-IP headers are ignored by default;
configure explicit trusted proxy CIDRs to use the verified proxy chain for client
budgets (see below). Shared PostgreSQL limits are available; account-level throttling remains pending.
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
sessions as described below; refresh remains blocked during takedown. Suspended
accounts cannot create or refresh sessions. Restrictions are enforced from current database status on each request,
including sessions issued before deactivation. Sessions survive process restarts.
Changing the signing key without a verification fallback invalidates existing tokens.
Session-key overlap is supported as described below. Write handlers recheck authorization inside the
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
(see authentication-state cleanup below).

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
- [ ] Full media decoding/validation.
- [x] Atomic nested record-reference tracking, ownership/metadata checks on writes, and withdrawal when the last reference is removed.
- [x] Public `com.atproto.sync.getBlob` and paginated `listBlobs`, with `since` filtering, repository status checks, and restrictive content headers.
- [x] Authenticated `com.atproto.repo.listMissingBlobs` with account-scoped CID pagination and referencing record URIs.
- [x] Internal staged-blob expiration with a 24-hour default grace period and a one-hour minimum.
- [x] Durable cleanup queue for withdrawn/expired blob ownership, shared-owner checks, PostgreSQL/S3 deletion, and retryable S3 failures.
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
- [x] Transactional per-repository block reference counts for quota/status inventory and garbage-collection lookups.
- [x] Bounded operator revision-history compaction preserving current heads and retained replay dependencies.
- [x] `getLatestCommit`, `getRepoStatus`, and paginated `listRepos` sync endpoints with persistent repository status.
- [x] `com.atproto.sync.getRecord` compact signed existence and absence proofs.
- [x] `com.atproto.sync.getBlocks` for current and retained historical repository blocks (1–100 CIDs; repeated `cids` query parameters).
- [x] Export consistency checks against the signed commit, tree root, and revision.
- [x] Internal deactivation, suspension, takedown, and reactivation; inactive repositories reject public reads, exports, and ordinary record writes. Authenticated migration imports/uploads allow deactivated accounts only.
- [x] Historical block retrieval with signed-commit and canonical-tree membership checks, including deleted records and prior MST nodes.
- [x] Internal durable event sequencing and cursor replay, recorded atomically with repository creation, writes, imports, and status changes.
- [x] Bounded operator event retention with a durable replay floor and `OutdatedCursor` stream notices.
- [x] Opt-in supervised event-retention scheduling with bounded batches, timeouts, and outcome telemetry.
- [ ] Higher-throughput sequencing (writes currently share a PostgreSQL transaction advisory lock to preserve commit order).
- [x] `com.atproto.sync.subscribeRepos` binary WebSocket stream with exclusive resume cursors, live delivery, and account status events.
- [x] Invalid/future cursor errors, bounded replay backlog, idle pings, and current-availability filtering for repository data.
- [x] Wire-format commit, sync, account, and identity event encoding, plus CBOR stream/error framing.
- [x] Commit CARs with full MSTs, changed records, prior roots, and operation metadata; oversized commits fall back to commit-only sync messages.
- [ ] Compact inductive commit proofs (event encoding currently includes the complete MST).
- [x] Internal `Atoll.Identity.Updates.refresh/2`: resolves hosted identities, verifies claimed handles, and atomically records changed observations with durable identity events.
- [x] Opt-in supervised identity refresh scheduling, with one task at a time, timeouts, sweep retries, and outcome telemetry.
- [x] Owner-authenticated identity refresh with fresh DID resolution and atomic observation events.
- [x] PostgreSQL-coordinated automatic identity refreshes with expiring leases and publication fencing.
- [ ] Remaining authenticated identity-management endpoints.
- [x] Configurable operator crawl announcements to relay `com.atproto.sync.requestCrawl` endpoints.
- [x] Opt-in supervised periodic crawl announcements to configured relays.
- [ ] Automatic relay discovery and federation interoperability tests.
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
more scalable signed-tree membership verification remains pending.

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

For local development, connect to
`ws://localhost:4000/xrpc/com.atproto.sync.subscribeRepos?cursor=0`.
Omit `cursor` to start at the current stream position; otherwise pass the last
received sequence number to replay later events. Messages are binary frames with
two concatenated CBOR objects (header and body), not JSON or Phoenix channels.
Idle connections poll PostgreSQL every 500 ms and send a ping every 15 seconds.
Connections more than 10,000 persisted events behind receive `ConsumerTooSlow`
and close; sequence gaps do not count toward this limit. Replay skips commit and
sync data for currently inactive repositories, but still emits account and identity events.
Internet deployment requires WSS termination; connection quotas,
and federation interoperability testing remain pending.

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
- [x] Configurable general XRPC request budget before parsing, in addition to specialized rate limits.
- [x] Explicit trusted-proxy CIDRs and bounded client-IP extraction for all request rate limits.
- [x] Optional PostgreSQL-shared request budgets across nodes, with bounded storage and fail-closed errors.
- [x] Operator account status reads, takedowns, restoration, and deactivation.
- [x] Account-scoped blob takedowns across PostgreSQL/S3 serving, uploads, references, and cleanup.
- [x] Operator record takedowns for JSON record reads and listings (signed sync data remains available).
- [x] Transactional history of successful account/record/blob subject-status decisions, with bounded operator export.
- [x] Operator account inspection, singly and in bounded batches, with private metadata and invite histories.
- [x] Audited operator email correction with invalidation of old email challenges.
- [x] Audited operator password replacement with session, app-password, and pending-code revocation.
- [x] Transactional audit history for account invite enable/disable decisions and private reason changes.
- [x] Transactional audit history for operator invite-code issuance and revocation, without redeemable codes.
- [x] Audited operator account deletion with durable shared-safe blob cleanup.
- [x] Operator account messages through the configurable email Worker, with attempt/outcome history.
- [ ] Remaining administrative account controls and audit coverage for other operator actions.
- [ ] Production configuration, HTTPS deployment, and signing-key protection.
- [ ] Database and blob backup / restore workflow.
- [x] `GET /health/ready` database connectivity readiness with bounded queries and outcome telemetry.
- [x] Opt-in supervised cleanup of expired sessions and service-token replay markers, with bounded batches and outcome telemetry.
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
unrecoverable. Changing it alone does not rotate existing encrypted keys; use the
master-key rotation workflow below.

With the master key configured, trusted internal callers can use:

```elixir
{:ok, head} = Atoll.Repositories.create_managed(did)
Atoll.Repositories.apply_managed_writes(did, operations, swap_commit: head.head)
```

For an existing repository whose private key is still available,
`Atoll.KeyVault.store(did, key)` persists it only if it matches the pinned public
key. Existing signing keys cannot be overwritten; the operator rewrap command can
replace their encrypted envelopes without changing their key material. These internal functions do
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
failure returns `validDid: false`. PLC operation-log authority is checked when audit
resolution is enabled; private-key availability is not checked. Remote resolution runs before inventory
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
refresh preserves the persisted scope. Every access check validates the JWT scope
against the session row or the explicit export-only restriction, and session creation rechecks that the app credential has
not been revoked.

Both scopes permit ordinary record writes, blob uploads, session inspection,
refresh, and logout. Account-management operations, repository migration imports,
and app-password management require a full account session. `getServiceAuth`
requires an explicit method for app sessions, rejects migration account creation,
and permits `chat.bsky.*` methods only for privileged app passwords. Existing
protected-method restrictions still apply. Already-issued service JWTs remain
valid until their short expiry. Password recovery revokes all app credentials as
well as sessions. Taken-down login temporarily narrows either app scope to
export-only access; restoration refresh recovers the persisted app scope, never
full account access. OAuth remains pending.


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
endpoint, path-based DID, localhost DID, or non-web DID returns 404 here, except
for the explicitly enabled localhost development mode described below. Other
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
nullification. Fresh signup uses the genesis primitives.
Persist a signed genesis operation before attempting registration: signing it again
can produce different bytes and therefore a different DID. Full audit validation
and automatic background registration retries remain pending.


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
below. Fresh signup uses this journal; automatic background retries remain pending.


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

These APIs are internal and do not authorize callers. Fresh signup invokes them after
validating account input and authenticating retries. No registration scheduler runs.
No live PLC registrations are performed by tests, migrations, or startup.


### Fresh account signup

Set `ATOLL_SIGNUP_ENABLED=true` to allow `com.atproto.server.createAccount` without
an existing DID or service token. It defaults to false. Configure a public HTTPS
PDS endpoint, the vault and session signing keys, and `ATOLL_AVAILABLE_USER_DOMAINS`
(for example `.users.example.com`). Route wildcard DNS and HTTPS for those user
hosts to Atoll; Atoll does not provision DNS or certificates. Handles must be one
label beneath an advertised domain. `GET /.well-known/atproto-did` serves completed
accounts by the actual request host, ignoring forwarded-host headers. Disabling
signup does not disable resolution of existing handles.

Supply `handle` and `password`, optionally `email`, `inviteCode`, and a valid secp256k1 or P-256
`recoveryKey` DID key. Handles and emails are normalized. The recovery key precedes
the server's independently generated PLC rotation key in priority. Phone
verification, custom-domain signup, and caller-supplied PLC operations are
not supported by this fresh-signup path; existing-DID migration still requires its
service JWT. Email confirmation uses the existing Worker-backed request endpoint.

Signup atomically reserves the profile, password, deactivated repository, encrypted
keys and signed genesis before contacting the directory. No login or hosted handle
resolution is available while registration is pending. After exact directory
confirmation, activation, completion and the initial session commit together.
The response contains the DID, handle, access JWT and refresh JWT. Requests retain
the existing 4 KiB body limit, no-store responses and 20-attempt direct-IP login
bucket per five minutes.

On a directory error, retry the same handle, password, email, invite code and recovery key.
The pending account and original signed operation are reused; changed passwords
or reservation details cannot take over a pending account. A concurrent password
reset invalidates an in-flight signup proof. Once signup is complete, further
create requests return an account-exists error; use login if the success response
was lost. Failed session creation leaves the confirmed reservation deactivated and
resumable. Pending reservations are retained indefinitely; automated cleanup and
background retries remain pending. No configuration in this change enables signup
on the running deployment or submits live registrations.


### DID resolution cache

Routine DID resolution caches successful, identity-matched documents on each node
for 60 seconds. Set `ATOLL_DID_CACHE_TTL_SECONDS` between 0 and 300; zero disables
storage. The supervised cache holds at most 256 entries, including in-flight
placeholders, and 8 MiB of serialized document payloads. Older entries are evicted
when either budget is exceeded. These payload limits exclude normal process/map
metadata. Expiry uses monotonic time and is checked on access; errors are not
cached and expired documents are never served as a fallback.

Service-JWT verification (including migration authorization), account activation,
account status checks, and identity refreshes force an authoritative network lookup.
Forced refresh removes the old cached result even if the request fails. Per-fetch
tokens prevent an earlier request from overwriting a later refresh. Network work
runs in the calling process outside the cache server. Cache restarts or failures
fall back to the resolver; simultaneous misses are not coalesced.

Trusted internal callers can pass `force_refresh: true` or `cache: false`. Custom
transport/DNS options bypass shared caching unless an explicit cache is supplied,
keeping test and alternate resolver data isolated. Each account-resolution call
still parses the document's signing key, PDS endpoint and handle; handle forward
lookups remain uncached. Multi-node cache invalidation and PLC log verification
remain pending. Existing SSRF checks, pinned addresses and response limits apply
on every network lookup.


### IPv6 identity resolution

DID and HTTPS handle resolution accept public IPv6 destinations as well as IPv4.
DNS selection prefers the first permitted A answer, then checks AAAA if there is no
permitted IPv4 result. Both lookups share a three-second DNS budget. The selected
address is pinned into the HTTPS URL; IPv6 uses a bracketed literal and an IPv6
socket. HTTP Host and TLS verification/SNI retain each requested domain. DID
redirects remain disabled; HTTPS handle redirects repeat these checks at every hop. This does not add connection racing or retry another address
when the selected address cannot connect.

The IPv6 policy permits `2000::/3` global unicast, excluding `2001::/23` IETF
assignments, `2001:db8::/32` and `3fff::/20` documentation ranges, and `2002::/16`
6to4. It also excludes all mapped/translated IPv4, loopback, unspecified, private,
link-local, multicast and other space outside that global-unicast range. This is
conservative: it excludes some globally reachable special-purpose assignments.
The policy follows the ranges in the [IANA IPv6 special-purpose registry](https://www.iana.org/assignments/iana-ipv6-special-registry/).
Tests cover address boundaries, DNS fallback, pinned URLs and transport options;
they do not depend on the test machine having public IPv6 connectivity.


### Localhost DID development mode

`ATOLL_LOCALHOST_DIDS_ENABLED=true` enables a narrow exception in development and
test builds only. The default is false; enabling it through runtime configuration
in production fails startup, and production-compiled code cannot enable the
exception by changing application environment values.

The resolver accepts `did:web:localhost` (HTTP port 80), or an encoded port such as
`did:web:localhost%3A4000`. Ports must be canonical decimal integers from 1 to
65535; `%3a` is also accepted. Paths, credentials, query/fragment suffixes, raw
colons, numeric IP DIDs and subdomains of `.localhost` are rejected. HTTP requests
are pinned directly to `127.0.0.1`, without DNS, and retain `localhost:port` as Host.
Existing timeouts, response limits, expected-document ID checks and redirect
rejection apply. This mode does not let public domains resolve to private addresses
or permit arbitrary HTTP service endpoints.

For a development PDS running on port 4000, set
`ATOLL_PDS_DID='did:web:localhost%3A4000'`, enable the flag, and supply a stable
`ATOLL_PDS_SIGNING_KEY`. Keep the endpoint URL configured as
`http://localhost:4000`; the DID port must match it. The existing
`/.well-known/did.json` route then publishes the public service key on requests
whose host is exactly `localhost`. DID document parsing accepts a plain-HTTP PDS
origin only for literal localhost while this mode is enabled. Localhost handles
and fresh PLC signup over HTTP are not enabled by this exception.

Tests include an actual HTTP round trip to an ephemeral loopback Atoll endpoint,
plus disabled-mode, port, host, redirect and private-address rejection checks.
No running server configuration is changed by this feature's default settings.


### Invite-code policy

Set `ATOLL_INVITE_CODE_REQUIRED=true` to require an invitation for account creation,
including existing-DID migration. It defaults to false, independently of the fresh
signup enable switch. `describeServer` reports `inviteCodeRequired`. A supplied
code is always validated and consumed, even when invitations are optional.

Operators can create a code in the configured database using:

```sh
mix atoll.invites.create --uses 1
```

The task prints JSON containing the code and use count. `--uses` accepts 1–10000;
`--for-account DID` optionally attributes the invitation to an existing local
account. This attribution does not authenticate the holder: the code is a bearer
invitation. Codes contain 192 random bits, are stored for account listings,
and are redacted in schema inspection and request parameter logs. Treat the task's
output as a secret to share with intended invitees. No invitations have been issued
outside rollback-isolated tests by this implementation work.

Redemption locks the code and records one historical use per DID inside account
provisioning. A database rollback restores the use. A committed pending fresh
signup retains its use across directory errors, and password-authenticated retries
must carry the same code; they never spend a second use. Account deletion does not
refund a use. A pending signup originally admitted without an invite can finish
after policy becomes stricter. `Atoll.Accounts.Invites.disable/1` is an internal
operator API that blocks new reservations without cancelling existing ones.

Migration redemption also rolls back with failed provisioning and service-token
consumption. HTTP issuance/disabling uses the separate operator authentication
below. Optional automatic allocation is described below; the Mix task and
internal APIs are trusted operator operations.


### Administrative invite endpoints

Set `ATOLL_ADMIN_PASSWORD` to a separate secret of 32–1024 printable, non-space
ASCII bytes to enable these routes. With no password configured they return 503.
Use HTTP Basic authentication with username `admin` and that password over the
PDS's HTTPS endpoint. Account access/refresh JWTs, app-password sessions and
service JWTs do not grant admin access. The admin password is independent of all
account passwords and signing/encryption keys; configure it in the deployment
secret store. This implementation does not configure a live admin password.

- `com.atproto.server.createInviteCode`: POST `useCount` (1–10000), optionally
  `forAccount` (an existing local DID); returns `code`.
- `com.atproto.server.createInviteCodes`: POST `codeCount` (1–500), `useCount`, and
  optional `forAccounts` (up to 100 distinct local DIDs). It creates `codeCount`
  codes for each supplied account, with at most 500 codes total. With no accounts,
  the response groups unowned codes under `admin`. A failed owner validation rolls
  back the entire batch.
- `com.atproto.admin.disableInviteCodes`: POST optional `codes` and/or `accounts`,
  each limited to 100 entries. It disables the selected codes and all codes
  attributed to those DIDs. Unknown codes/accounts and an empty selection are
  harmless no-ops. Existing signup reservations remain redeemable as described
  above; new reservations are rejected.

These methods accept POST JSON bodies up to 16 KiB. Authentication occurs before
body parsing and is checked again by the controller. Responses use `no-store`;
failed authentication includes a Basic challenge. A separate per-node client-IP
bucket allows 60 admin attempts per five minutes, including failed authentication;
client addresses honor the explicit trusted-proxy configuration. Account-wide disabling has a
one-second lock timeout and five-second statement timeout, rolling back on timeout.
Invite codes are filtered from request-parameter logs. Account moderation uses
the same operator authentication, as described below; other administrative methods
remain pending.


### Invite-code listings

`GET com.atproto.admin.getInviteCodes` uses operator Basic authentication. It accepts
`sort=recent` (default) or `sort=usage`, `limit=1..500` (default 100), and an opaque
`cursor`. Recent order uses creation time descending, with code as a deterministic
tie-breaker. Usage order sorts by redemption count first. Cursors are tied to their
sort mode. Pagination is a live view: new redemptions can move codes between usage
pages. Cursor values are filtered from request logs because they contain code data.

Pages include complete redemption histories, with at most 10,000 use records total;
a page may contain fewer codes than its requested limit to stay within this bound.
Continue through its returned cursor. The original code use allowance appears as
`available`, matching the protocol; subtract `uses.length` to calculate remaining
uses. Each use contains `usedBy` and `usedAt`. Codes also include `disabled`,
`forAccount`, `createdBy`, and `createdAt`. Operator-issued codes use `createdBy: "admin"`;
earned codes use the owner DID. Unowned codes have `forAccount: "admin"`.

`GET com.atproto.server.getAccountInviteCodes` requires a full account session;
app-password sessions are rejected. It returns only codes attributed to that DID.
`includeUsed=false` excludes exhausted codes; the default includes them. Disabled
codes remain visible with their disabled flag. `createAvailable` accepts a boolean (default true) and allocates earned codes when
the optional policy below is enabled; false performs a read-only listing.
This unpaginated protocol method allows at most 1,000 codes and 10,000 use records;
larger results return an error directing operators to admin pagination, never a
silently truncated list.

Both queries reject request bodies and unknown/malformed parameters, use no-store
responses, and retain their respective admin/session rate limits. Listing reads
serialize with invite mutations to keep counters and histories consistent, with
one-second lock and five-second statement timeouts. Database indexes support the
recent, usage and account-owned orderings. Histories include redemptions by deleted
accounts because deletion does not refund invitations.


### Automatic invite allocation

Set `ATOLL_INVITE_INTERVAL_SECONDS` to an interval from 3600 to 31536000 seconds;
zero (the default) disables allocation. Set `ATOLL_INVITE_MAX_OPEN` from 1 to 1000
(default 5) to cap unused, non-disabled earned codes per account. Allocation also
requires `ATOLL_INVITE_CODE_REQUIRED=true`, an active repository, and a locally
confirmed account email. Missing profiles and unconfirmed or deactivated accounts
receive no newly earned codes.

On a full-session `getAccountInviteCodes` request with `createAvailable=true`, the
account earns one single-use code for each complete interval since its local
profile creation. Already-issued earned codes, including spent and disabled ones,
count against that lifetime interval entitlement. Issuance fills only the available
space under the open-code cap. Older accounts may have a backlog; spending a code
can make room to issue another from that backlog. Future-dated profiles receive no
credits. Operator gifts neither use earned credits nor count against the open-code
cap. Changing the interval changes the calculated entitlement; existing codes are
retained. No allocation scheduler or epoch-reset mechanism is configured.

Allocation runs in the authenticated listing transaction under the invite mutation
lock. Repeated or concurrent requests cannot multiply an entitlement, and a failed
listing rolls back new codes. `createdBy` identifies earned codes by the account
DID. Email confirmation uses the existing Cloudflare Worker flow; allocation itself
sends no email and does not enable any production policy automatically.

New reservations using account-owned codes are rejected if the owner is taken down,
suspended, or deleted. Deactivated owners' existing codes remain usable. This check
is repeated at redemption, while already-committed signup reservations retain their
original authorization. Disabling current codes does not prevent future allocation;
use the account controls below to pause automatic issuance.


### Per-account invite controls

The operator-authenticated POST methods
`com.atproto.admin.disableAccountInvites` and
`com.atproto.admin.enableAccountInvites` accept `account` (a local DID) and optional
`note` (valid UTF-8, up to 2000 bytes, without NUL). They return an empty 200 response.
Missing local account profiles return an account-not-found error. They inherit
admin authentication, body limits, rate limits and no-store responses.

Disabling stops automatic earned-code issuance; it does not invalidate existing
codes, revoke sessions, or change repository status. Operators can still explicitly
gift codes to the account. Use `disableInviteCodes` separately to revoke existing
codes. Enabling resumes normal age-based allocation, including any eligible backlog
under the unused-code cap. Other eligibility checks still apply.

The flag, latest private note, and change timestamp are updated atomically with the
same lock ordering as allocation and redemption. Repeating the same flag and note
is idempotent. An omitted note clears the previous note on a change. Notes are
redacted in schema inspection and request logs and are not returned in invite lists.
Every successful call also appends a private audit entry in the same transaction,
including repeated decisions and note-only changes. Entries retain the requested
note and before/after flag, note, and change timestamp. Failed authorization,
validation failures, and rolled-back changes leave no audit entry. History survives
account deletion and is available through `mix atoll.moderation.history`; it contains
no invitation codes. No email or public repository event is sent for these controls.


### Administrative account status

`GET com.atproto.admin.getSubjectStatus?did=...` returns a local repository subject
(`com.atproto.admin.defs#repoRef`) and its `takedown` and `deactivated` attributes.
Each attribute includes `applied`; a takedown can also contain an operator's private
`ref`. Missing local repositories return `400 NotFound`.

`POST com.atproto.admin.updateSubjectStatus` accepts the same repository subject
and optional `takedown` and `deactivated` attributes. For example:

```json
{
  "subject": {
    "$type": "com.atproto.admin.defs#repoRef",
    "did": "did:plc:example"
  },
  "takedown": {"applied": true, "ref": "case-123"}
}
```

Set `takedown.applied` to `false` to lift it. A takedown preserves the underlying
active, deactivated, or suspended state. Lifting it restores that state; it cannot
accidentally publish a previously deactivated or suspended repository. Operators
can change deactivation while a takedown is in effect, but cannot apply a takedown
and request activation in the same call. This endpoint cannot clear a suspension.
Existing takedowns created before migration `20260926131424` have no recorded prior
state and conservatively restore to deactivated. Explicit operator activation is
an administrative override; it does not perform the owner's DID/key readiness checks.

Changes take the event lock before the repository row lock and commit atomically
with an account event when public availability changes. Repeating a state change
or editing a private reference does not duplicate events. Public reads, exports,
blobs, ordinary writes, and session-management checks enforce takedown; the owner
export exception is described below. Stored data
and sessions are retained, and usable sessions resume when availability is restored.
The account owner cannot lift a takedown using activation/deactivation endpoints.

These routes require the separate operator Basic credentials above, authenticate
before parsing, share the 60-attempt/five-minute admin rate limit, and return
`no-store` responses. JSON updates are limited to 16 KiB; writes have one-second
lock and five-second statement timeouts. Takedown references are UTF-8 strings of
at most 2000 bytes, excluded from request-parameter logs and public events. Applying
a takedown without `ref` clears the previous reference; lifting it also clears it.
`deactivated.ref` is not retained in current state; it remains in the audit
request snapshot. Current state is accompanied by the operator decision history
described below.

Record and blob subjects are supported as described below. Each subject type has
its own enforcement boundary; record visibility controls do not withhold signed
repository synchronization data.


### Administrative blob takedowns

The same subject-status endpoints support account-scoped blob moderation:

- `GET com.atproto.admin.getSubjectStatus?did=...&blob=...` accepts a local DID and
  canonical raw blob CID. It returns a `com.atproto.admin.defs#repoBlobRef` subject
  and its `takedown` attribute.
- `POST com.atproto.admin.updateSubjectStatus` accepts that blob subject and an
  optional `takedown` attribute, using the same `applied`/private `ref` fields as
  account takedowns. `recordUri` is optional context and must name a record under
  the subject DID; it does not restrict the takedown to that record. Blob subjects
  cannot have a `deactivated` attribute.

```json
{
  "subject": {
    "$type": "com.atproto.admin.defs#repoBlobRef",
    "did": "did:plc:example",
    "cid": "<canonical raw blob CID>"
  },
  "takedown": {"applied": true, "ref": "case-123"}
}
```

A takedown hides bytes from `getBlob` and excludes the CID from `listBlobs` and
`listMissingBlobs`. Uploading the same bytes or writing another record that references
them fails with `BlobTakendown`. This applies to PostgreSQL and S3 storage and to
staged blobs. Other accounts owning the same CID remain unaffected; a takedown does
not delete a shared object or take down the account.

Markers are stored separately from ownership and survive record deletion, staged
expiration, and byte cleanup. Operators can read or lift a retained marker even
after ownership has gone. A new restriction requires existing local ownership;
an unknown blob returns `NotFound`. Markers are removed when the account is deleted.
Lifting a takedown restores serving if referenced bytes still exist; otherwise the
owner can upload them again. This does not recreate bytes already collected.

Blob moderation takes the event lock before the repository head lock, serializing
with uploads, record writes, import, and cleanup. It does not rewrite signed records,
remove their blob descriptors, or emit a fabricated repository commit. Imports may
retain descriptors for restricted blobs, but serving/upload checks remain in force
and migration's missing-blob inventory omits them until the restriction is lifted.
Private references stay out of public events and request logs. Previously downloaded
copies on other services are outside this PDS's control.


### Administrative record visibility

`GET com.atproto.admin.getSubjectStatus?uri=...` accepts a full record AT URI with
a local DID, collection, and record key. It returns a `com.atproto.repo.strongRef`
subject and its `takedown` attribute. Handle authorities are not accepted for
operator targets. Use that subject in `POST com.atproto.admin.updateSubjectStatus`
with `takedown: {"applied": true}` (optionally a private `ref`) or `false` to lift it.
Record subjects do not accept `deactivated`.

**Record takedown filters `com.atproto.repo.getRecord` and `listRecords`; it does
not withhold signed sync exports or event replay.** This follows the separation in
the upstream [indexed record reader](https://github.com/bluesky-social/atproto/blob/main/packages/pds/src/actor-store/record/reader.ts)
and [signed repository reader](https://github.com/bluesky-social/atproto/blob/main/packages/pds/src/actor-store/repo/sql-repo-reader.ts).
The record remains reachable through `sync.getRepo`, `sync.getRecord`,
`sync.getBlocks`, and historical subscription events. Use an account takedown to
withhold public repository synchronization. Blob bytes have their separate,
account/CID takedown described above; hiding a record does not hide its attachments.

A hidden record returns `RecordNotFound` from the JSON API, including historical
CID requests at that URI. Listings exclude restrictions before pagination, in both
sort directions. Other record paths and accounts remain visible even if they have
identical record CIDs. Collection inventories continue to describe the signed
repository, including collections containing hidden records.

Updates take the event lock and repository head lock, and compare the submitted
strong reference CID with the current record. A stale CID returns `InvalidSwap`
without changing moderation state. Public record reads and listings hold a shared
head lock, so they observe a consistent visibility decision and record snapshot.
The operator can moderate inactive accounts without changing their availability.
Repeated changes are idempotent, private refs use the existing 2000-byte limit and
log filtering, and no moderation operation rewrites the signed tree or fabricates
a repository event.

Atoll retains the URI restriction across owner edits, delete/recreate, and CAR
imports. Owners can still edit or delete their records, but these operations do not
lift the restriction. Status reads return the current CID when present, or the last
moderated CID for a deleted record; operators can lift a retained restriction using
that returned subject. A missing record without a retained restriction returns
`NotFound`. Account deletion removes its restrictions. Operator decisions are also
recorded in the audit history described below.


### Moderation decision history

Every successful `com.atproto.admin.updateSubjectStatus`,
`com.atproto.admin.updateAccountEmail`, `com.atproto.admin.updateAccountPassword`,
`com.atproto.admin.disableAccountInvites`, `com.atproto.admin.enableAccountInvites`,
or `com.atproto.admin.deleteAccount` call records an audit entry in the same database transaction as its change.
Entries include the subject, requested attributes, before/after state, UTC time,
and the shared operator identity `admin`. Account snapshots also include effective
and underlying availability, so deactivation changes beneath a takedown are visible.
Email snapshots contain the old/new private address, confirmation timestamp, and
email-factor setting, but never challenge codes, digests, or credentials. Password
replacement entries contain only the target DID and revoked session/app-password
counts, never the submitted password or its hash.
Repeated decisions and private reference changes are recorded even when no public
event is emitted. Validation errors, stale CIDs, failed authorization, and rolled-back
transactions do not create decision entries.

History starts with migration `20260926133109`; earlier decisions cannot be
reconstructed. Entries survive account deletion and have no automatic retention
limit. The application only appends entries; this is not a tamper-proof log against
database administrators. The shared Basic credential does not identify individual
human operators. Owner lifecycle changes, direct `Repositories.set_status` calls,
direct internal invite issuance/revocation, automatic invite allocation, and failed
authentication attempts are outside this decision log's current coverage.

Export one page from the trusted operator console:

```sh
mix atoll.moderation.history --limit 100
mix atoll.moderation.history --limit 100 --after 123
mix atoll.moderation.history --did did:plc:example
```

The task is read-only and uses the configured database. `--limit` accepts 1–1000;
`--after` is an exclusive nonnegative audit ID. Results are JSON with `entries`, plus
`cursor` when another page exists. Pass that cursor to the next invocation; keep the
same DID filter when paging. IDs and cursors are strings to preserve 64-bit integer
precision. Entries are ordered by ID, with successful writes serialized through the
existing event lock; rolled-back transactions may leave sequence gaps.

This export intentionally contains private moderation references, including for
deleted accounts. Those fields are redacted from schema inspection and excluded
from SQL parameter logging and public events. No passwords, authorization headers,
or session tokens are stored. There is no public history endpoint or automatic
external export.


### Export-only sessions during takedown

`com.atproto.server.createSession` accepts `allowTakendown: true`. After normal
password or app-password verification, an account whose current status is
`takendown` receives an access JWT with scope `com.atproto.takendown`, plus a refresh
JWT. The response reports `active: false` and `status: "takendown"`. Without this
explicit option, login remains blocked. Active/deactivated accounts retain their
normal scopes. Suspension, including a suspension underneath a takedown, is not
bypassed. Main-password email factors still require a single-use code delivered
through the configured Cloudflare Worker.

Supply the access JWT as `Authorization: Bearer ...` to these owner-export routes:

- `com.atproto.sync.getRepo` (including the existing optional `since` revision).
- `com.atproto.sync.listBlobs` (including pagination and `since`).
- `com.atproto.sync.getBlob`.

Exporting an inactive repository requires a token belonging to the requested DID.
Existing ordinary owner access tokens also permit these exports for active,
deactivated, or taken-down accounts. A live token can read another account only
when that target remains active and public. Invalid, expired, revoked, and refresh
credentials are rejected; omitting credentials preserves public availability checks. Export success
responses are `no-store`. Head and session locks are held while reading the data,
so availability and revocation checks remain part of the read transaction. Blob
exports only include currently referenced owned blobs and still enforce individual
blob takedowns. Staged/unreferenced blobs remain private to internal storage APIs.

A taken-down scope grants no ordinary writes, uploads, imports, service tokens,
account/app-password management, `getSession`, `checkAccountStatus`, or deletion-code
requests. This restriction continues after the operator restores the account;
existing restricted access JWTs never acquire broader privileges. Logout using
the refresh token remains available. Refresh is blocked while taken down; after
restoration, it rotates once and issues the original persisted full or app-password
scope. Revoking an app password invalidates its restricted sessions too. Access
expiry (two hours), refresh expiry (90 days), account session caps, and password
recovery revocation apply unchanged.

These exports do not reactivate the account or reopen public synchronization.
These three routes also accept the configured operator Basic credential
(`admin` plus `ATOLL_ADMIN_PASSWORD`). Operators can export any existing local
repository, including suspended accounts, without changing its status. Basic
requests use the shared administrative rate limit (60 requests per five minutes per
client IP), authenticate before query parsing, and reject invalid credentials even
when the requested data would otherwise be public. Missing operator configuration
returns 503 for Basic requests; unauthenticated public reads remain available.

Storage authorization rechecks the supplied operator credential and holds a shared
repository lock for the export. Blob references, individual blob takedowns, existing
CAR size limits, pagination, and revision filters still apply. This override does
not authorize other sync methods, writes, uploads, or account operations. Export
reads do not append moderation decisions to the audit history.


### Administrative account inspection

`GET com.atproto.admin.getAccountInfo?did=...` returns the local account's DID,
stored handle, profile creation time (`indexedAt`), email and confirmation time when
present, owned invite codes with usage history, the invite used to register the
account when recorded, and invitation controls (`invitesDisabled` and optional
`inviteNote`). Fields are explicitly selected; password hashes, email token digests,
private signing material, and session credentials are never part of the response.

`GET com.atproto.admin.getAccountInfos` accepts 1–100 DIDs as repeated `dids` query
parameters (the `dids[]` spelling also works) and returns `{ "infos": [...] }`.
Duplicate DIDs produce one entry in first-requested order. Missing accounts are
omitted from batch responses; a missing single account returns `400 NotFound`.
A local repository without an account profile is not an account-info result.
Deactivated, taken-down, and suspended accounts remain inspectable by operators.
For current availability use `getSubjectStatus`; `deactivatedAt`, threat signatures,
and related records are omitted because those optional metadata are not tracked.

Both routes require the separate operator Basic credentials, authenticate before
query parsing, share the admin rate limit, and return `no-store`. Reads use the
event lock and account/profile share locks for a consistent metadata/invitation
view, with one-second lock and five-second statement timeouts. They do not allocate
earned invitations, change state, resolve remote identities, or send email.

A response is limited to 1000 distinct invite codes and 10,000 expanded usage
entries across all account views, including repeated appearances of a shared
`invitedBy` code. Oversized histories return an explicit error instead of a partial
account view. Use smaller DID batches or `com.atproto.admin.getInviteCodes`
pagination to inspect large invite histories.

### Operator email correction

`POST com.atproto.admin.updateAccountEmail` accepts JSON `account` (local DID or
handle) and `email`, with the configured operator Basic credential. It returns an
empty 200 response. Addresses are normalized using the same rules as owner email
updates; an address already held by another account is rejected.

Changing the address clears email confirmation, disables the email login factor,
and invalidates all outstanding confirmation, email-change, password-reset, login,
and deletion codes and their cooldowns. Passwords, app passwords, and existing
sessions remain valid. The operation works on inactive accounts without changing
their availability. Repeating the same normalized address preserves confirmation
and pending codes. Both changes and no-ops enter the private operator audit history;
no public repository event is emitted.

This endpoint does not send a message automatically. The owner can request
confirmation using `com.atproto.server.requestEmailConfirmation`; that request and
all subsequent email flows use the configured Cloudflare Worker and the new address.

### Operator password replacement

`POST com.atproto.admin.updateAccountPassword` accepts JSON `did` and `password`
with the configured operator Basic credential and returns an empty 200 response.
Passwords use the same UTF-8, 8–1024-byte policy and Argon2id hashing as account
password recovery. Hashing happens before acquiring database locks.

The replacement atomically revokes every existing access/refresh session and app
password, invalidates all pending email codes and their cooldowns, and appends a
private audit entry. Previously verified password proofs cannot create new sessions
after the replacement. Other accounts are unaffected. Repeating the same password
still revokes credentials and codes.

Confirmed email, the email login-factor preference, identity, repository data, and
account availability remain unchanged. Inactive accounts can be repaired without
activating them. The operation requires an existing profile and password credential;
it does not provision an account. No email is sent automatically. Subsequent login
codes and recovery messages continue through the configured Cloudflare Worker.

### Operator account deletion

`POST com.atproto.admin.deleteAccount` accepts JSON `did` with the configured
operator Basic credential and returns an empty 200 response. It can remove active,
deactivated, suspended, or taken-down local repositories, including incomplete
provisioning without a profile or password. Unknown/already-deleted DIDs return
`NotFound` without another event or audit entry.

Deletion uses the same removal transaction as owner-authorized account deletion:
account data, sessions, credentials, repository ownership, and encrypted local
keys are withdrawn; previous events for the DID are removed; one public deleted
account event is appended. Physical blob deletion is queued durably and performed
by the existing cleanup worker or operator cleanup command. PostgreSQL and S3 bytes
still owned by another account are retained. Repository blocks remain subject to
the separate unowned-block collection policy.

The private audit records prior availability and deletion in the same transaction,
and survives along with previous audit and invitation-use history. Failed requests
and rolled-back transactions retain account data and leave no deletion audit entry.
This endpoint does not send email, require an owner email code, or tombstone the DID
in PLC. It removes the account from this PDS; it cannot erase copies held elsewhere.

### Owner-requested identity refresh

`POST com.atproto.identity.refreshIdentity` takes a full account access token and
JSON `identifier` containing the account's DID or a handle resolving to that DID.
Atoll restricts this endpoint to the requesting account; app passwords and
taken-down export tokens cannot use it. Active and deactivated accounts are
supported. Refreshing another DID returns `Forbidden`.

The response contains `did`, the bidirectionally verified `handle` (or
`handle.invalid`), and the complete `didDoc`. DID lookup bypasses and refreshes the
node-local cache. DNS/HTTPS resolution retains the existing public-address checks,
timeouts and response limits. DID redirects are rejected; handle redirects follow
the bounded HTTPS policy described below. Missing identities return
`DidNotFound` or `HandleNotFound`; other resolution failures preserve the previous
observation and return an error. PLC-log verification follows the configured
resolution policy.

Resolution runs outside database locks. Before storing the observation, Atoll
rechecks the live session and account availability under the repository/event lock
order. Revocation during resolution prevents publication. Observation changes and
identity events commit together; unchanged observations emit no duplicate event.
Refreshing does not change the account's stored handle, signing key, hosting status,
or DID document at its authority.

Requests have a 4 KiB JSON limit, no-store responses, and share the per-node
login/recovery budget of 20 requests per five minutes per direct client IP. This
endpoint does not provide distributed request coalescing or replace the optional
periodic refresh worker.

### Public identity resolution

`GET com.atproto.identity.resolveDid?did=...` returns `{ "didDoc": ... }` for a
resolved DID, without requiring an ATProto signing key or PDS service and without
verifying a handle. `GET com.atproto.identity.resolveIdentity?identifier=...`
accepts a DID or handle and returns `did`, `handle`, and `didDoc`. It requires valid
ATProto identity fields and verifies the document's claimed handle back to the DID;
an absent or unverified claim is returned as `handle.invalid`. Handle input is
case-insensitive. Neither endpoint requires a local account or authentication.

Queries use the existing bounded positive DID cache, public-address-pinned HTTPS
resolver, DNS handle resolution, and response/time limits. DID lookups reject
redirects; HTTPS handle lookups follow the bounded policy below. Query parameters
cannot override resolver options. Resolution performs
no account mutation and emits no identity event. Owner `refreshIdentity` remains
the explicit fresh-resolution and observation-update path.

A missing DID or handle returns `DidNotFound` or `HandleNotFound`; invalid documents
and upstream failures return `InvalidRequest` without upstream response bodies.
The resolver does not currently distinguish a deactivated PLC DID from a missing
DID. Audit mode independently verifies the operation log before deriving the
DID document.

All three public identity queries (`resolveDid`, `resolveIdentity`, `resolveHandle`)
share a per-node limit of 60 requests per five minutes per direct client IP, return
no-store responses, and reject request bodies. Query parsing retains the existing
32 KiB bound and Lexicon parameter validation.

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
per-account abuse policy, or a Redis backend. HTTP guards consume budgets before
handler transactions, so a failed handler does not restore its request allowance.

### HTTPS handle redirects

The HTTPS fallback for handle resolution follows up to three redirects (four
requests total), as allowed by the [handle specification](https://atproto.com/specs/handle#https-well-known-method).
Supported statuses are 301, 302, 303, 307, and 308. Relative and cross-host locations
are accepted, provided every destination uses HTTPS on port 443 with a valid,
non-reserved DNS hostname. IP-literal destinations, embedded credentials, fragments,
and control/space characters are rejected. A response must provide exactly one
`Location` value of at most 2048 bytes.

Every hop performs fresh address resolution, checks the public-address policy,
and pins the chosen IP while preserving that hop's Host and TLS hostname. This
also applies to redirects back to the same hostname. Automatic client redirects
and retries stay disabled. Each response, including redirect bodies, retains the
4 KiB handle-response limit; each hop retains the three-second DNS and five-second
HTTP budgets. A loop fails when the hop allowance runs out. The periodic identity
worker's existing overall task deadline still applies.

DID-document resolution and PLC-directory submission continue to reject redirects.
DNS TXT still takes precedence over HTTPS, and a successful redirect only proves
the forward handle claim; bidirectional verification still checks the DID document.

### Handle-resolution cache

Successful normalized handle-to-DID claims are cached separately from DID
documents. `ATOLL_HANDLE_CACHE_TTL_SECONDS` controls the TTL (default 60 seconds,
range 0–300; zero disables caching). The node-local cache holds at most 256 entries
and 1 MiB of serialized payload. It caches only successful syntactically valid DID
claims, never lookup failures or ambiguous DNS results. Reserved/invalid handles
are rejected before cache lookup.

Routine handle resolution and repository reads reuse claims within this TTL, then
re-resolve DNS or HTTPS. Bidirectional checks still require the DID document to
claim the requested handle. Cache failures fall back to resolution. A forced
refresh replaces the previous claim; failure removes that claim rather than
returning stale data. Tokens identifying in-flight lookups prevent an older result
from overwriting a newer forced refresh. There is no distributed cache or
concurrent-request coalescing.

Handle login, handle-based repository writes, migration account provisioning, and
owner/periodic identity refreshes force fresh handle resolution. Login and writes
also force fresh DID resolution. Public queries cannot set trusted resolver options
to bypass these policies. Internal calls use `force_refresh: true`; test/custom
transports disable the shared handle cache unless explicitly supplied with
`handle_cache: cache_pid`.

### Encryption master-key rotation

`ATOLL_KEY_ENCRYPTION_KEY` remains the active base64-encoded 32-byte AES key used
for every new repository-key and PLC rotation-key envelope.
`ATOLL_PREVIOUS_KEY_ENCRYPTION_KEYS` optionally supplies up to four comma-separated
base64 32-byte decryption-only keys. Keys are never accepted as CLI arguments or
stored in PostgreSQL. Malformed environment values fail startup. Application
configuration uses `:key_encryption_key` and `:previous_key_encryption_keys` with
decoded 32-byte binaries.

For a deployment with multiple nodes, rotate in these stages:

1. Generate and securely back up a new random 32-byte key. Distribute it as a
   decryption-only fallback to every node while retaining the old active key.
2. Switch every node to the new active key, retaining the old key as a fallback.
   Complete this rollout before rewrapping so no node continues writing old envelopes.
3. Run `mix atoll.keys.rewrap --limit 100` with the same active/fallback configuration.
   If JSON output contains `cursor`, pass it to the next invocation with `--after DID`.
   Continue until there is no cursor. Use the production environment and secret
   source when operating a production database.
4. Repeat a complete pass from the beginning to verify every envelope is readable
   with the active key; it should report zero rewrapped envelopes. Remove the old
   fallback from every node only after the complete successful pass. Keep old keys
   securely available for backups made before the rotation.

Each page scans at most 100 repositories in DID order and commits atomically.
Output contains only `scanned`, `repositories` and `plc` rewrap counts, `unchanged`
envelope count, and an optional DID cursor. Repositories without stored envelopes
are counted as scanned but need no change. An unreadable/tampered envelope or
database failure aborts the entire page; repair and retry that page without
skipping the affected account. The command is resumable and idempotent.

Rewrapping takes the event lock followed by repository and envelope locks, with
bounded lock/statement waits. It preserves the authenticated envelope binding,
private/public signing-key material, repository commits, signed PLC operation,
registration state, sessions, and public events. Both repository keys and retained
PLC rotation keys must migrate before retiring an old master key.

This rotates encryption protection, not repository signing keys, PLC authority,
JWT secrets, or server identity keys. It cannot recover an envelope when every
key capable of decrypting it has been lost. No rotation is scheduled automatically.

### Session JWT signing-key rotation

`ATOLL_SESSION_SIGNING_KEY` always signs newly issued access and refresh JWTs.
`ATOLL_PREVIOUS_SESSION_SIGNING_KEYS` optionally contains up to four comma-separated
base64-encoded 32-byte keys used only to verify existing tokens. The active key
must remain configured. Malformed fallback configuration fails startup; keys never
come from request parameters or JWT headers. Application configuration uses
`:previous_session_signing_keys` with decoded 32-byte binaries.

For a rolling rotation, first distribute the new key as a verification fallback
to every node while the old key remains active. Then switch all nodes to the new
active key with the old key retained as a fallback. Existing sessions continue
working, and each successful refresh rotates once to tokens signed by the active
key. New logins also use only the active key. No database rewrite is required.

Remove the old fallback once its remaining tokens may be invalidated. Access JWTs
live for two hours; refresh JWTs can live for 90 days from their last issuance.
Retain overlap for that maximum period after the last node stopped signing with
the old key if all otherwise-valid refresh tokens must survive. Removing a key
earlier forces holders of its remaining tokens to log in again. For a compromised
key, remove it promptly rather than preserving overlap.

Every candidate key is subject to the same HS256 algorithm, exact token-type,
audience, scope, lifetime, and claim checks. Persistent session revocation and
one-use refresh-token hashes still apply; accepting a signature under a fallback
key does not restore a revoked session. Trusted internal callers with an explicit
`:secret` do not inherit runtime fallbacks unless they explicitly provide
`:previous_secrets`. This key ring is separate from repository encryption master
keys, repository signing keys, PLC rotation keys, and service identity keys.

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


### Operator email messages

`POST com.atproto.admin.sendEmail` uses the existing admin Basic authentication,
60-request/five-minute client-IP budget, 16 KiB JSON body limit, and `no-store`
responses. Its pinned upstream Lexicon requires `recipientDid`, `senderDid`, and
`content`; `subject` and `comment` are optional. The recipient must be a local
account with a stored email address. Active, deactivated, suspended, and taken-down
accounts can receive operator messages. A missing account returns `NotFound`;
a missing email returns `InvalidEmail`.

Atoll sends plain text through `Atoll.Email.deliver/3` using
`ATOLL_EMAIL_WORKER_URL` and `ATOLL_EMAIL_WORKER_TOKEN`, just like every other
email feature. Only the stored recipient email, subject, and content reach the
Worker. The Worker controls the sender address and delivery provider. `senderDid`
is an operator-supplied audit attribution, not proof of DID control or an email
From override. `comment` is private review context and is never sent in the email.
The default subject is `Message from your PDS operator`. Local bounds are 1–12000
UTF-8 bytes for content, 1–200 for a supplied subject (no control characters), and
0–2000 for a supplied comment, subject to the total JSON body limit.

Before delivery, Atoll stores a `prepared` audit entry with an opaque message ID,
recipient/sender DIDs, and optional private comment. It does not store the email
address, subject, body, Worker secret, or response body in this history. Delivery
runs after the preparation transaction releases its locks, using the captured
address; a concurrent address change or account deletion cannot recall that
message. A second entry with the same message ID records `accepted`, `rejected`,
`unavailable`, or `not_configured`. These entries use the existing private
`mix atoll.moderation.history` export and survive account deletion.

A successful response is `{ "sent": true }`, meaning Worker acceptance, not
confirmed inbox delivery. Worker failures return a generic 503. A crash or an
outcome-audit failure can leave only the prepared entry, even if delivery occurred;
this is an unknown outcome, not evidence that nothing was sent. There is no
automatic retry or durable outbox. Each new API call gets a new message ID, so an
operator retry after an ambiguous failure may send a duplicate. Tests use mocked
Worker requests and send no actual email.


### Invite-code operator audit history

Successful `com.atproto.server.createInviteCode`,
`com.atproto.server.createInviteCodes`, and `com.atproto.admin.disableInviteCodes`
requests now append audit history in the same transaction as their changes.
Validation failures, missing batch accounts, and failed authorization create no
entries. Rolling back issuance or revocation also rolls back its audit entry.
These actions emit no public repository events.

Issuance records the requested use count and account attribution, the number of
created codes, and SHA-256 fingerprints of the codes. Batch issuance groups those
fingerprints by attributed account, within the existing 500-code bound. Revocation
records the selected accounts and deduplicated explicit code fingerprints, plus
matched, enabled, and disabled counts before and after. Overlapping selectors count
a code once. Already-disabled, unknown-code, and empty selections are still recorded
as successful decisions, including no-ops. Account-wide revocation uses aggregate
counts; it does not copy an unbounded set of affected codes into the audit table.
Redeemable codes are never stored in these audit entries.

Migration `20260926145606` allows a null audit `did` for server-wide decisions.
Single-code issuance attributed to an account retains that account's DID; unowned
issuance, batch issuance, and revocation have `did: null`. Use the unfiltered
`mix atoll.moderation.history` export to include server-wide entries; `--did` only
selects entries attributed directly to that DID. The subject is the internal
`{ "kind": "inviteCodes" }` audit descriptor. The migration's rollback deliberately
fails while null-DID entries exist, rather than deleting operator history.

History identifies the shared `admin` credential, not an individual human.
Internal `Atoll.Accounts.Invites` calls and automatic account invite allocation do
not fabricate an admin API audit entry. Existing audit retention and access rules
apply, including retention after account deletion.


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


### Offline PLC audit verification

Verify a saved PLC `/log/audit` JSON response against an explicitly supplied DID:

```sh
mix atoll.plc.verify did:plc:ewvi7nxzyoun6zhxrhs64oiz audit-log.json
```

The command performs no network requests or database changes. It reads at most
8 MiB and accepts 1–1000 entries, using `Atoll.Identity.PLC.AuditLog.verify/2`.
Output contains the DID, verified last-operation CID, tombstone status, and counts
of active and nullified operations. Invalid, mismatched, oversized, or unreadable
input fails without printing its contents.

Verification derives the DID from the signed genesis, recomputes every operation
CID, verifies signatures with the predecessor's authorized rotation keys, and
reconstructs the active chain in submission order. It rejects duplicate operations,
unknown or already-nullified predecessors, updates descending from a tombstone,
backwards timestamps, and forged `nullified` flags. A recovery must use a strictly
higher-priority key at the fork point than the key that signed the first displaced
operation, arrive after the latest submission, and fall within 72 hours of that
first displaced operation. Exactly 72 hours is accepted. Valid recovery can displace
a tombstone; a surviving final tombstone is reported as deactivated history.

Historical verification accepts the empty or repeated rotation-key lists present
in the upstream compatibility fixtures, within the five-key bound. Empty keys
cannot authorize a subsequent operation. Atoll's signing API still requires one
to five distinct rotation keys when creating modern operations. Existing canonical
signature, curve, encoding, operation-size, and structural checks remain in force.
The new recovery fixtures use the same pinned upstream revision and MIT provenance
recorded in `test/fixtures/plc/README.md`.

This validates the supplied history, not proof that it is complete or current.
Directory timestamps are unsigned metadata; cryptographic verification cannot
independently establish when an operation was submitted or detect an omitted
newer suffix. Live resolution can use the verified audit policy described below.
Local signing-key rotation and recovery workflows remain pending.


### Verified PLC resolution

Set `ATOLL_PLC_RESOLUTION_MODE=audit` to derive `did:plc` documents from independently
verified operation history. The application setting is
`config :atoll, :plc_resolution_mode, :audit`. The default `directory` mode preserves
the existing HTTPS trust policy; only `directory` and `audit` are accepted at startup.
The setting applies to shared resolver callers, including public identity queries,
service-token verification, login identity checks, activation, and identity refresh.
Hostname-level `did:web` resolution is unchanged.

Audit mode fetches `https://plc.directory/<did>/log/audit` with the resolver's existing
public-address checks, DNS address pinning, TLS hostname verification, five-second
request timeout, and no redirects or automatic retries. It accepts at most 8 MiB
and 1000 operations. Verification checks the genesis, signatures, CID chain,
recovery authority/window, timestamps, and declared nullifications as described
above. No rendered DID document is requested and no directory-trust fallback is
attempted on invalid, unavailable, or oversized history.

The surviving operation supplies the aliases, Multikey verification methods, and
services. Legacy genesis operations are normalized to those document fields.
A surviving tombstone resolves as `did_not_found`; a properly recovered tombstone
can resolve normally. Invalid logs become `invalid_did_document`. The ordinary
ATProto key/PDS extraction and bidirectional handle checks still apply afterward.

Verified and directory-trusted documents have separate keys in the bounded positive
cache. Switching to audit mode cannot reuse a document cached under the directory
policy. Forced refresh replaces or invalidates the relevant verified entry, using
the existing TTL, byte/count bounds, and protection against stale in-flight loads.
The setting is trusted server configuration, never a public request parameter.
`ATOLL_PLC_DIRECTORY_URL` still controls registration submission only; the shared
resolver's public PLC source remains `plc.directory`.

Verification authenticates operation contents and their permitted transitions. It
still relies on the supplied directory timestamps and cannot prove the response is
complete or detect an omitted newer suffix. No durable last-seen checkpoint or
independent witness service is implemented. Oversized histories fail closed in
audit mode rather than being partially verified. Tests mock network traffic and
exercise pinned upstream logs, invalid recovery, tombstones, response/address
bounds, and cache isolation; they do not mutate any external DID.


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

Reference counts and quota usage update transactionally. Physical block deletion
is a separate `atoll.blocks.prune` operation after its own grace period; shared
owners remain protected. Historical reads lose access through compacted revisions,
and exports with a compacted `since` revision fall back to a full current snapshot.
Current exports and retained replay frames remain valid. Back up dependency rows
alongside events and revisions. This does not reduce the full-tree rebuild cost of
writes or eliminate complete block arrays for retained revisions.


### PLC update submission

`Atoll.Identity.PLC.Client.submit_update/4` submits an already signed and persisted
ordinary update to the configured `ATOLL_PLC_DIRECTORY_URL`. It verifies the update
signature and predecessor CID locally, reads the directory's latest operation, and
posts only when that operation matches the trusted predecessor. If the update is
already latest, retry succeeds without posting again. After POST, only an exact
latest-operation CID match counts as success, even after a timeout or HTTP error.
A different latest operation reports conflict; callers must not silently re-sign
or overwrite it. Reads use the same bounded HTTPS transport as genesis submission.

This is an internal transport primitive. Callers must authenticate the predecessor's
chain to the requested DID, authorize the user action, and durably retain the exact
signed update before submission. The initial read does not lock the remote directory;
the directory arbitrates concurrent operations under its PLC rules. This path does
not submit recovery forks against older predecessors. It does not itself change
local profiles, repository signing keys, or session state. Authenticated handle,
key rotation, and recovery workflows remain pending. Behavior follows the
[PLC update specification](https://web.plc.directory/spec/v0.1/did-plc).
