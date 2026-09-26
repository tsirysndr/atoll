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
- [ ] Persistent repository signing keys and secure key lifecycle management.
- [x] PostgreSQL repository heads and atomic record, tree, and commit updates with optional head compare-and-swap.
- [x] Internal record create, put, delete, and read operations with collection/type checks (not Lexicon validation).
- [x] Public `getRecord` and paginated `listRecords` for repository DIDs and current record versions.
- [ ] Handle lookup and historical CID versions for record reads.
- [ ] Record writes and deletion (`createRecord`, `putRecord`, `deleteRecord`, `applyWrites`).
- [ ] Repository description (`com.atproto.repo.describeRepo`).
- [x] In-memory CARv1 encoding and decoding with block verification and resource limits.
- [x] Consistent repository CAR export through the internal storage API.
- [ ] Repository CAR import and streaming large transfers.

### Identity, accounts, and authentication

- [ ] DID document resolution and verification (`did:plc` and `did:web`).
- [ ] Handle resolution, verification, and updates.
- [ ] Account creation, activation, deactivation, and deletion.
- [ ] Password hashing, email verification, and account recovery.
- [ ] Session creation, refresh, inspection, and revocation.
- [ ] App passwords.
- [ ] ATProto OAuth authorization and resource server support.
- [ ] Authorization checks for account and repository operations.
- [ ] Account migration, identity updates, and signing-key lifecycle.

### Blobs

- [ ] Blob upload with MIME type and size validation.
- [ ] Account-scoped blob metadata and record references.
- [ ] Blob retrieval and listing.
- [ ] Blob lifecycle management and cleanup.

Raw CID support and generic block storage are implemented; the ATProto blob API is not.

### Synchronization and federation

- [x] Full repository export via `com.atproto.sync.getRepo` (in-memory, 64 MiB archive limit).
- [ ] Incremental repository exports using `since` (currently rejected explicitly).
- [x] `getLatestCommit`, `getRepoStatus`, and paginated `listRepos` sync endpoints (all stored repositories currently active).
- [ ] Sync endpoints for blocks and record proofs, plus inactive repository status handling.
- [ ] Durable repository event sequencing and replay.
- [ ] `com.atproto.sync.subscribeRepos` WebSocket stream with resume cursors.
- [ ] Commit, sync, identity, and account events.
- [ ] Relay discovery / crawl requests and federation interoperability tests.
- [ ] Service authentication and request proxying to AppViews and other services.

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

## Checks

```sh
mix precommit
```

The test alias creates the test database and applies pending migrations. Database tests use Ecto's SQL sandbox to roll back their changes.

## Protocol references

- [AT Protocol overview](https://atproto.com/guides/overview)
- [Data model and CID formats](https://atproto.com/specs/data-model)
- [Repository format](https://atproto.com/specs/repository)
- [Synchronization](https://atproto.com/specs/sync)
- [OAuth](https://atproto.com/specs/oauth)

## License

[MIT](LICENSE)
