# Test suites and drills

The opt-in integration suites, interoperability checks, and restore drills.

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

Uploads are staged incrementally on disk with a 1 GiB limit, 64 KiB body reads,
a five-second per-read timeout, and a 30-second overall read budget. The declared
length must match the actual bytes. Imports allow ten attempts per peer IP per
five minutes using the configured memory, PostgreSQL, or Redis request limiter.
Blob bytes must be transferred separately. Record bodies are read individually
from private staging during validation and atomic publication. Tree traversal,
record publication and blob-reference reconciliation use bounded application
metadata; block bodies and the staging CID/offset index reside on disk. Normal
completion, malformed input, read errors, and publication failures close and remove
the staging files. A VM/host crash may leave private files behind; monitor
temporary-disk capacity and clean stale files operationally.

For migration, `createAccount` requires an existing DID, a bidirectionally verified
handle, a password, and a one-use service JWT for this PDS and the createAccount
method. Email is optional. It creates a deactivated account and installs the signing
key reserved for that DID, or generates a new encrypted key when none was reserved.
`getRecommendedDidCredentials` returns that key and this PDS endpoint;
PLC authority-key custody is managed separately from repository signing keys. Before activation,
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
Legacy access JWTs accept active or deactivated accounts; DPoP OAuth access tokens
require an active account. Both share the session endpoint's
300-request per-IP, per-five-minute limit. Pagination reflects current state
rather than a snapshot across requests.

`GET /xrpc/com.atproto.server.checkAccountStatus` accepts a legacy access JWT
(including for inactive accounts) or a DPoP OAuth access token for an active account,
and reports activation, current commit/revision,
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

### Database backup and restore primitives

`python3 scripts/recovery_set.py backup|verify|restore DIRECTORY` pairs the
database and optional S3 archives with a checksum manifest. Backup and restore
require `--offline`; backup also takes `--storage`, `--revision`, and
`--keyring-reference`. See the runbook for exact commands, stopped-writer
prerequisites, external key/config custody and partial-failure handling.

See [the logical database archive runbook](../ops/backup/README.md) for
`scripts/database_backup.py backup|verify|restore DIRECTORY`, PostgreSQL version
requirements, separate encryption-key custody, isolated restore targets, and the
remaining S3/restore-drill work. The helper and full-schema Atoll drill were tested with disposable PostgreSQL
18 databases. `scripts/test_atoll_database_backup.py` verifies signed exports,
key decryption, authentication, PostgreSQL blobs and replay state after restoring
all migrations. Push CI runs both restore drills against its disposable PostgreSQL
18 service with matching archive clients. No development or production data was
backed up or restored.

For S3 bytes, `mix run --no-start scripts/s3_backup.exs backup|verify|restore DIRECTORY`
provides an offline, bounded-memory archive helper. It verifies every blob's CID,
refuses a populated target `blobs/` prefix, and checks upload readback. Follow the
runbook's stop-writers requirements; the helper does not synchronize a database
snapshot with a live bucket or preserve provider versions/metadata.

### Official OAuth client integration

An optional `interop` test uses the existing `@atproto/oauth-client-node` **0.3.16**
package against a supervised Atoll server on a random localhost HTTP port:

```sh
ATOLL_ATPROTO_OAUTH_CLIENT_PATH=/absolute/path/node_modules/@atproto/oauth-client-node \
  mix test --include interop test/atoll_web/atproto_oauth_e2e_test.exs
```

The harness checks the package name/version without installing dependencies. The
SDK performs resource and authorization discovery, PKCE/PAR with server nonce
retry, authorization-code exchange and issuer verification, DPoP resource access
with nonce retry, and refresh rotation. The HTTP browser harness follows login
and explicit consent with cookies and CSRF fields. Base and confidential cases
use SDK `signOut()` and require a successful revocation request, an empty grant
inventory, and a surviving source session. Other cases log out the source session
and verify that SDK resource access fails. Callback URLs are inspected
and passed to the SDK, never fetched. Requests are restricted to the temporary
server origin, with five-second request and 45-second overall deadlines. Test
accounts, tokens and keys are disposable and database changes roll back.

Identity resolution uses a fixed synthetic DID document pointing at the temporary
server; the SDK still checks that document's PDS against discovered issuer metadata.
Nine cases cover confidential-client flows plus localhost public clients with base
`atproto` scope, granular repository/blob grants, an email-read grant, and an RPC
grant using each repository signing curve (secp256k1 and P-256). The base grant
cannot write records. The granular flow
requests create/update access to one collection but approves only create; the SDK
receives the narrowed scope and can create records before and after refresh.
Updates, deletes, cross-collection creates, and batches mixing permitted and
forbidden operations return `insufficient_scope`. Reads and a database assertion
verify preserved record contents and no partial batch writes. Refresh preserves
the consented scope rather than restoring declined permissions.

The blob scenario requests text and PNG upload permissions, approving only text.
It verifies successful text uploads and rejects PNG, JSON, and PNG bytes declared
as text, both before and after refresh. The blob grant cannot write records, and
the base grant cannot upload blobs. Database assertions compare the exact stored
raw CIDs and bytes with the two permitted uploads, proving rejected uploads leave
neither blob metadata nor PostgreSQL blob bytes. This harness uses PostgreSQL blob
storage; it does not establish upstream OAuth interoperability with S3 storage.

The email scenario requests read and management permissions but approves only read.
The SDK sees the granted email address and confirmation status, while base,
repository and blob grants omit both fields. Email authentication settings remain
hidden. Every scenario rejects email-update/confirmation requests and mutations
with `insufficient_scope`, before and after refresh. The full account profile,
including pending challenge fields, remains unchanged. Email delivery is disabled
for the harness; no external Worker receives messages.

The RPC cases approve one method on one service audience and decline a second
requested method. SDK requests obtain service JWTs before and after refresh;
Node's crypto verifier independently checks each signature against the fixture's
public key, plus issuer, exact audience/method, one-minute lifetime, and distinct
nonces. Omitted methods, declined methods, changed service fragments, bare audiences,
and foreign hosts are rejected. Other grant families cannot mint these tokens;
source-session logout prevents further issuance. Already issued service JWTs remain
valid until their expiry. The test does not send these tokens to an external service.

The harness uses the PostgreSQL rate limiter so counters roll back with each test;
this preserves real admission limits without sharing a loopback IP budget across
independent scenarios. Prior limiter and application settings are restored afterward.

The confidential-client case uses an ephemeral ES256 key and the SDK's
`private_key_jwt` authentication for PAR, code exchange, and refresh. Atoll retrieves
an inline JWKS from a controlled Req transport fixture; all authorization requests
still use real loopback HTTP. Assertions are recorded in the replay store, and the
persisted grant binds the client key ID, algorithm, and thumbprint. A synthetic
private JWK is passed only to the child process environment and never printed;
metadata contains only the public key. No dependencies or real client keys are
installed or changed.

Two additional confidential cases change the fixture's advertised key after code
exchange: one removes the original key ID, and one replaces its material under
the same key ID. The SDK refresh receives `invalid_grant`; database assertions
confirm deletion of the OAuth grant and every access token while retaining the
source password session. The browser account session remains usable. These cases
exercise observed key changes at refresh, not periodic key-checker timing or real
remote metadata/JWKS HTTPS transport.

These tests do not establish live DID/handle resolution, remote client metadata
interoperability, RPC proxying, identity permissions, email management or repository import, browser rendering, or
complete OAuth profile compliance.
The development-only HTTP identity exception is enabled only for this test and
restored afterward. The `interop` tag remains excluded from default tests and CI
because the SDK must be installed separately.

### Official ATProto client integration

An optional `interop` test starts Atoll on a random loopback HTTP port and drives
it with `@atproto/api` **0.13.35**, covering session login, record writes and
swaps, blob upload/publication, private preference round trips (including the
derived declared-age preference and anonymous rejection), read-after-write
timeline splicing and unindexed-thread recovery against a stubbed stale
AppView (with the client validating the munged views), and firehose
consumption. It independently verifies served CAR commits,
MST contents, record inclusion and deletion-absence proofs with `@atproto/repo`
**0.8.10**, using the test account's signing public key for both secp256k1 and P-256
repositories. `@atproto/xrpc-server` **0.7.19** supplies the upstream WebSocket
subscription/frame decoder; the API package validates commit event schemas.
These are pinned test versions, not a claim of compatibility with all client releases.
The integration suite has been run locally with Node.js 24.13.1.

With Node.js and existing installations of those three packages, supply their
absolute package-directory paths:

```sh
ATOLL_ATPROTO_API_PATH=/absolute/path/node_modules/@atproto/api \
ATOLL_ATPROTO_REPO_PATH=/absolute/path/node_modules/@atproto/repo \
ATOLL_ATPROTO_XRPC_SERVER_PATH=/absolute/path/node_modules/@atproto/xrpc-server \
  mix test --include interop test/atoll_web/atproto_client_e2e_test.exs
```

The harness checks package names and exact versions and does not install or
modify them. It creates a synthetic account and encrypted signing-key custody in
the test database's rollback sandbox. The Node client's requests are restricted
to the temporary server's origin and redirects are rejected. HTTP requests and
WebSocket handshakes have five-second deadlines, subscriptions have ten-second
deadlines, and the overall client deadline is 45 seconds. The supervised
server stops after the test; no real accounts or credentials are used.

Coverage includes password login, session inspection/refresh/revocation,
schema-validated Bluesky posts with server-generated keys, create/put/delete and
batch writes, rejected stale record swaps, anonymous record reads, pagination,
blob upload/publication/download, full repository exports and signed record
proofs. The pinned client decodes `text/plain` blob responses as strings; the
test compares their encoded bytes with the upload. It explicitly supplies the
current refresh token for session deletion.

Firehose checks begin with an independently verified baseline repository. The
upstream subscriber replays create, update, batch and delete commits after that
baseline cursor. The repository verifier checks each signed CAR against the prior
mirror and compares its computed changes with the event's operations, including
new and prior record CIDs. Tests check increasing sequences, prior revisions,
`prevData`, commit CIDs and revisions, and the mirror's resulting records. An
already connected subscriber receives a new write; a second connection resumes
at the last consumed cursor and receives only the following delete. The final
mirror matches the HTTP repository head. A future cursor is decoded as an upstream
`FutureCursor` error.

This test is excluded from `mix precommit` and CI because it requires separately
installed upstream packages. OAuth, handle/DID discovery, account creation,
migration, relay federation and newer client versions are outside this test's
coverage. Firehose sync fallback, identity/account events, expired replay windows
and slow-consumer behavior are also outside this upstream integration test; local
tests cover those paths separately. Full external-client/server interoperability
remains on the checklist.

### MinIO integration tests

With Docker running, the local test PostgreSQL database available, Python 3.9+,
matching PostgreSQL client tools on PATH, and a database role with CREATEDB:

```sh
bash scripts/test_minio.sh
```

The script builds a test image from MinIO's pinned
`RELEASE.2025-09-07T16-13-09Z` source release, starts a disposable container on a
random localhost port, waits for readiness, and runs the `minio`-tagged tests and
the combined database/S3 restore drill. The latter uses explicit
`PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD` settings (local defaults otherwise), creates
two disposable databases, and removes them after the drill.
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

