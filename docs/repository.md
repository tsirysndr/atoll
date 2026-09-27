# Repository internals

Lexicon discovery, inclusion proofs, and CAR encoding, decoding, and import staging.

### Lexicon namespace discovery

`Atoll.Lexicon.Authority.discover/2` maps an NSID namespace to its repository DID.
For `edu.university.dept.lab.blogging.getBlogPost`, it queries exactly
`_lexicon.blogging.lab.dept.university.edu`. It removes only the final name segment,
reverses the authority labels, and normalizes only those labels to lowercase. The
case-sensitive schema name is preserved in the resulting record URI:
`at://DID/com.atproto.lexicon.schema/NSID`. This follows the
[Lexicon publication/resolution rules](https://atproto.com/specs/lexicon#lexicon-publication-and-resolution)
and [NSID normalization rules](https://atproto.com/specs/nsid).

There is no parent-domain search or handle/HTTPS fallback. Duplicate identical DID
claims are accepted; conflicting valid claims fail. Invalid/unrelated TXT values
are ignored within a bounded response: at most 32 records, 16 chunks per record,
255 bytes per chunk, 2052 bytes per joined record, and 16 KiB total. Overlong DNS
names and reserved authority domains fail before lookup. The system DNS resolver
has a three-second timeout; no additional application cache is used.

`Authority.resolve/2` additionally forces fresh DID resolution to obtain the
repository signing key and PDS endpoint through the existing protected resolver.
The account handle need not match the namespace: DNS delegation establishes that
binding. This trusts the configured/system DNS resolution path; it does not add
DNSSEC validation. Discovering a repository does not yet authenticate a schema.
Tests use mock DNS/HTTP.

`Atoll.Lexicon.Fetcher.fetch/2` performs that discovery and fetches
`com.atproto.repo.getRecord` from the resolved HTTPS PDS. It pins a public IP while
preserving TLS hostname verification and the Host header, including nondefault
ports. It sends no account credentials, follows no redirects, performs no automatic
retries, and accepts at most 256 KiB of uncompressed response JSON. Duplicate JSON
keys and nesting deeper than 64 levels are rejected.

The returned URI must exactly match the delegated DID, schema collection, and
normalized NSID. The value must declare the schema record type, Lexicon version 1,
matching `id`, and nonempty named definitions. Its canonical DAG-CBOR SHA-256 CID
must match the response CID. Success returns the document and its DID/URI/CID
provenance without installing it. Before returning success, it also requests
`com.atproto.sync.getRecord` from the same PDS, bounded to 2 MiB, and verifies the
CAR's signed commit with the freshly resolved account key. The MST inclusion path
must identify the same schema CID as the JSON response. Invalid, missing,
wrongly signed, or mismatched proofs fail without an unsigned fallback. A record
change between the two reads can therefore fail the request; no automatic retry
is made. Returned provenance includes the signed commit CID and revision.

This still trusts DNS and DID resolution to identify the publisher and signing key.
A valid older commit signed by that key can prove historical inclusion; the proof
does not independently establish the latest revision. The PDS's current-record
response supplies the freshness assertion. Signing-key rotation during retrieval
may cause verification to fail until a new request resolves the updated identity.

`Atoll.Lexicon.Catalog.resolve/2` follows external references through the same
independent discovery/fetch process for each namespace. It supports the record
schema language accepted by the operator catalog loader, strips the publication
`$type` envelope, and validates all definitions and reference targets before
returning a catalog. Missing dependencies, unsupported definitions, invalid union
targets, and unresolved fragments reject the whole result. Cycles are permitted;
each namespace is fetched at most once. Bundled schemas take precedence and are
never fetched remotely or replaced.

One resolution permits at most 16 remote documents and 1 MiB of aggregate
re-encoded schema JSON, in addition to the fetcher's per-response limit. A
30-second elapsed-time budget is checked between fetches and before accepting
the completed catalog. An in-flight DNS/HTTP operation retains its individual
timeout, so this is not a hard 30-second cancellation deadline. Results contain
the validated catalog plus DID/URI/CID/commit/revision provenance for each remote document; no
global configuration, cache, or database state changes. Transport/clock options
are trusted test hooks, never request parameters.

With `ATOLL_NETWORK_LEXICONS=true`, authenticated create/put/applyWrites requests
resolve unknown collections before opening the write transaction. A batch shares
one catalog budget across its collections and dependencies. Bundled and
operator-configured schemas retain precedence. `validate: false` skips discovery;
known local collections and delete operations also need no network lookup.
Required validation rejects unavailable or unsupported remote catalogs. Optimistic
validation proceeds with `unknown` status when catalog resolution fails, while
still enforcing known local schemas. A successfully resolved record schema is
enforced in either mode, and invalid records are rejected before mutation.
Catalog resolution is all-or-nothing: a failed batch dependency discards the
remote catalog for that request. Authorization is checked before discovery and
again under the repository lock, so session revocation during lookup prevents the
write. The remote catalog is a per-request snapshot; no schema cache is installed.
Internal write APIs and CAR import retain their existing data-integrity policy.

### Verifying record inclusion proofs

`Atoll.MST.Proof.verify/3` checks a partial search path against a supplied root and
returns its record CID, or `nil` for a proven absence. Missing path blocks are
errors, not evidence of absence. Visited blocks must match their DAG-CBOR CIDs,
use canonical encoding and key-prefix compression, sort keys within the inherited
subtree bounds, and follow the SHA-256-derived tree levels without skipping empty
intermediate nodes. Limits are 129 visited nodes, 1 MiB per node, 2 MiB of retained
path-node bytes and 10,000 entries per node. Sibling subtrees need not be supplied; the verifier does not claim to
validate their structure or the complete repository.

`Atoll.MST.Proof.fetch/4` performs the same validation through a CID reader that
returns `{:ok, bytes}`. It returns only the visited blocks and the record CID (or
`nil` for absence), and never requests sibling subtrees. The default retained-node
budget is 2 MiB; trusted internal callers can set `max_bytes` between 1 byte and
64 MiB. Crossing that budget stops traversal with `mst_proof_too_large`. Missing,
corrupt or malformed selected nodes fail rather than becoming absence proofs.

`com.atproto.sync.getRecord` now uses this loader against the verified current
commit's signed root, with the repository head locked throughout export. It checks
the commit revision and the requested record-index entry against the proof, then
loads only the selected record block. It no longer reconstructs the complete MST
from every index row. Unrelated index rows or sibling blocks are not audited by
this endpoint; full export retains its whole-index consistency check. Selected
index inconsistencies still fail closed. Inactive repositories remain unavailable.
Tests compare fetched paths with constructed canonical trees, enforce exact byte
budgets, and distinguish unrelated damage from selected-path corruption.

Whole-tree traversal is available for streamed HTTP exports as described below.
Signing-key rotation and recovery also validate the stored tree against the streamed
record index. Recovery reads and verifies distinct record bodies one at a time
before repairing custody, including same-key restoration. Changed-key transitions
stage authenticated tree/record CIDs in batches of 256 in a transaction-local
PostgreSQL temporary table, deduplicate there, and construct the retained revision
array inside PostgreSQL. They do not copy potentially damaged old membership
indexes or accumulate tree/membership maps in Elixir. The database role needs the
`TEMP` privilege. Temporary tables are dropped after insertion or at transaction
end; quota checks, custody changes and sync events remain atomic. PostgreSQL still
materializes the revision array and its indexes, and large repositories incur
multiple traversal passes while holding the write lock.
Staged imports validate canonical MST nodes and each record through bounded
traversal, then replay lazy record/CID streams during atomic publication. Record
rows insert in batches of 1,000; revision membership uses the same PostgreSQL
staging mechanism as key transitions. Migration re-signing replaces the commit
without collecting reachable CIDs. Validation still exhausts every branch before
publication, verifies record hashes/types/data-model limits, and rejects missing
blocks even when public storage contains them. Repeated traversal trades extra
reads for bounded tree metadata. The stage must remain open through publication.

Import blob-reference reconciliation marks imported rows with the advancing
revision, including surviving path/CID pairs. PostgreSQL finds previously referenced
owned blobs absent from the new revision, queues byte cleanup in batches of 256,
and deletes stale ownership and reference rows in the publication transaction.
Moving a reference preserves ownership; uploads never referenced by the old
repository remain staged. Other accounts' ownership is preserved, and physical
byte deletion remains the cleanup worker's responsibility. Rollback restores the
previous references and ownership without leaving cleanup jobs.

Staged HTTP imports now keep the archive, CID/offset index and revision membership
on disk or in PostgreSQL, with bounded application traversal and publication batches.
The buffered `Snapshot.decode/5` API collects its archive, records and blocks, with
a default 64 MiB retained-output accounting budget. Trusted callers may override
it with `max_buffer_bytes:`. Each expanded record path is charged for its bytes,
CID and a 128-byte map-entry allowance; each unique reachable block is charged for
its bytes, CID and a 96-byte allowance. Shared record blocks count once, while
every referencing record path counts separately. Unreferenced input blocks are
discarded, and reachable CIDs are consumed incrementally without building a list.
Exceeding the output budget returns `{:error, :car_too_large}` without a partial
snapshot. The buffered input still has its independent 64 MiB CAR/100,000-section
limits; input buffers and traversal state can coexist with output maps, so this
accounting budget is not an exact heap-size limit. `Snapshot.from_stage/4` keeps
its streamed interface and does not collect these output maps.
Ordinary record mutations now load previous values only for their at most 200
changed paths, persist their changes transactionally, and feed a 128-row sorted
record cursor to `MST.Builder.build/3`. Completed canonical nodes are emitted to
block storage immediately. The builder keeps pending ancestor entries under a
16 MiB accounting budget, with 10,000 entries/1 MiB per node, 100,000 emitted nodes
and one million input records. It preserves exact prefix compression and empty
intermediate levels. Invalid/unsorted input, exhausted budgets or failed writes
abort construction; partial emissions require a transaction or staging. Final
revision membership is built through bounded traversal and PostgreSQL staging.
Quota, blob-reference, head and event failures roll the entire mutation back.

Writes still rebuild the whole tree and perform work proportional to record count;
this is not incremental path mutation. Pending-byte accounting is not a precise
BEAM heap measurement. Public batch/body limits still bound prepared records, and
the database materializes revision arrays. `MST.load/3` now uses the canonical
traversal directly instead of collecting records and rebuilding the tree. It
returns the same fully buffered tree, but caps retained metadata at 64 MiB by
default (`max_bytes:` overrides this for trusted callers). Accounting charges
each encoded node plus its CID and a 96-byte map-entry allowance, and each expanded
record path plus its CID and a 128-byte allowance. Expanded paths count even when
prefix compression makes the encoded tree small. This is an accounting budget,
not an exact heap-size limit; traversal's independent 16 MiB pending budget and
node/depth/count limits also apply. Exhausting the retained budget returns
`{:error, :mst_too_large}` without a partial tree or further block reads. Invalid
or noncanonical trees return `{:error, :invalid_mst}`. The loader accepts either a
block map or a reader callback and never reads record bodies or unrelated blocks.
Callers needing a stream should use `MST.Traversal.stream/3` directly.

`MST.new/2`, `put/4` and `delete/3` apply the same default 64 MiB retained-metadata
accounting limit and `max_bytes:` option. Construction checks the record map's
expanded paths and CIDs before allocating sorted construction entries, then
charges encoded nodes as they are emitted. It also enforces one million records,
100,000 unique nodes, 10,000 entries per node and a 1 MiB encoded-node limit.
Exhaustion returns `{:error, :mst_too_large}` without a partial tree; invalid
paths/CIDs return `{:error, :invalid_mst}`. Mutation failures leave the input tree
unchanged. Options apply to each call, rather than being stored in the tree.
These helpers remain fully buffered: caller-owned inputs, previous tree versions,
sorting lists and encoding buffers can coexist with the output, so accounting is
not a promise of a 64 MiB total process heap. The separate streaming builder remains
the production write path and the buffered constructor remains an independent
canonical reference implementation.

`describeRepo` streams its complete collection array instead of materializing all
names in the application. PostgreSQL deduplicates and sorts names in bytewise
order; a cursor fetches 128 names at a time and JSON encoding uses batches of 128.
The DID document and reciprocal handle lookup resolve before opening this cursor.
The repository is rechecked as active and held with a shared head lock during
enumeration, with a 60-second transaction timeout. Client cancellation stops
enumeration and closes the cursor; failures after headers have been sent abort
the response rather than returning a truncated but valid JSON collection array.
No collection names are silently omitted and there is no pagination change.

Trusted callers can use `Repositories.stream_collections/2` or
`Repositories.Description.stream/3` to consume the cursor within its owning
transaction. Buffered `Repositories.collections/2` retains a default 64 MiB
accounting budget (`max_bytes:`), charging each name's bytes plus a 64-byte list
entry allowance. `Description.get/2` exposes this as `max_collection_bytes:`.
Overflow returns `{:error, :repository_metadata_too_large}` without a partial
list. These budgets do not constrain PostgreSQL's distinct/sort work or promise
an exact process heap size; the HTTP endpoint uses streaming rather than imposing
the buffered helper's collection limit.

The metadata-memory checklist covers the audited repository write, staged import,
full/differential export, historical read, record/block proof, key-transition and
collection-inventory paths, plus explicitly budgeted buffered helpers. Streaming
does not make full-tree operations constant-time or eliminate database revision
arrays and indexes. Callers of streaming helpers must preserve their lazy contract.

`Atoll.MST.Editor.apply/4` edits a caller-authenticated partial tree using up to
200 `{:put, path, cid}` / `{:delete, path}` operations. It lazily reads search paths
and split/merge boundaries, preserves unvisited subtrees as opaque CID links,
re-encodes canonical prefixes, and creates/prunes empty intermediate/root nodes
as needed. Results contain the new root, fetched original nodes and generated
nodes; nothing is persisted. An encoded-byte accounting limit (default 16 MiB,
including a per-map-entry allowance) bounds both node caches. Per-node size/entry
limits and key-derived levels constrain decoding. This is not a precise heap
measurement or a full-tree audit; the caller must authenticate the starting root
and validate the intended operation semantics.

Tests compare hundreds of edits with independent full canonical reconstruction,
exercise root-height changes, and replay a mixed batch's inverse using only its
fetched boundary proof. Missing required nodes, bad CIDs, malformed operations,
and exhausted budgets fail closed. This editor is the foundation for compact
inductive commit proofs and is now used by firehose encoding.

`Repositories.CommitProof.build/4` reverses up to 200 unique-path operations over
the new tree and requires the resulting root to match `prevData` (or the canonical
empty root for the initial commit). It separately proves each operation's new CID
or deletion absence against the original new tree, preventing false operation CIDs
from passing merely because reversal restores the old root. It returns only the
original nodes fetched for search and split/merge boundaries; generated inverse
nodes are not emitted. The retained-node editor budget is 16 MiB, and unchanged
subtrees are neither read nor audited.

Commit-event encoding also checks the previous commit's DID and revision against
the event's `since`, adds hash-verified created/updated records of at most one
million bytes, and emits a CAR capped at two million bytes. Oversized proofs or
editor-budget exhaustion retain the existing commit-only `#sync` fallback. Invalid
operations, mismatched roots or missing/corrupt required nodes fail closed. Empty
commits need only the root proof; deletion proofs include required merge/split
boundaries. Historical replay uses immutable retained blocks, not the current head.
Tests reverse emitted partial slices, reject tampered operation metadata, and show
that a mixed edit in a 2,000-record repository uses less than one tenth of its full
export. Eight offline cases have additionally been verified by the independent
TypeScript `@atproto/repo` 0.8.10 implementation: it reconstructs prior roots from
Atoll's exact partial proof slices, including a maximum mixed batch. Normal tests
pin the reference roots and verified slices without requiring Node. See
[test/fixtures/mst/README.md](../test/fixtures/mst/README.md) for provenance, scope and
reproduction commands. Signed event transport and live relay/client interoperability
remain separate pending suites.

`Atoll.Repositories.RecordProof.verify/5` accepts a CAR of at most 2 MiB, an
expected DID/path, and a trusted signing curve/public key. It checks the first CAR
root's version-3 commit signature, follows the MST proof to the requested record,
and returns that record plus its CID, commit CID, and revision. The record block
must be present, hash correctly, fit the 1,000,000-byte record limit, and declare
the requested collection. Wrong keys, mismatched DIDs, absent records, truncated
proofs, and tampered blocks fail. Both k256 and P-256 are supported.

The caller must authenticate the signing key and establish freshness separately.
A valid older signed commit can still prove historical inclusion; this API neither
resolves identity nor proves that the commit is the latest. Network Lexicon
retrieval invokes this verifier and requires its record CID to match the JSON
response. The structure follows the
[repository specification](https://atproto.com/specs/repository).

### Streaming CAR encoding

`Atoll.CAR.encode_stream/2` returns `{:ok, enumerable}` of binary CARv1 chunks:
first the header, then one framed section per supplied `{cid, bytes}` block. It
preserves source order (including duplicate sections), so a caller can place the
commit first without sorting or collecting the archive. CID hashes and the 2 MiB
section limit are checked before each block is emitted. The header retains the
buffered codec's limits; the streamed archive has no aggregate 64 MiB cap.

The source must be lazy to keep memory bounded. Consumer cancellation or a block
validation exception releases an upstream `Stream.resource`, including resources
owned by a database stream. Invalid roots fail before enumeration. Invalid blocks
raise `ArgumentError` during enumeration; callers must abort the transfer because
earlier chunks may already have been sent. They must also provide snapshot
consistency, authorization, and transfer-duration limits. Tests consume a stream
larger than 64 MiB without collecting it and check resource cleanup on cancellation
and validation failure. `com.atproto.sync.getRepo` now uses this encoder through
`Atoll.Repositories.stream_export/4`. It verifies the signed snapshot before sending
headers, then sends the commit first, MST nodes, and record bodies read individually
from PostgreSQL. Incremental exports omit blocks owned by the retained `since`
revision; unknown revisions still receive a full export. Client chunk-write failure
halts enumeration and releases the transaction. Corruption found after headers
aborts the stream rather than attempting a JSON error response.

A shared repository-head lock prevents mutation, deletion, or revision compaction
from invalidating the snapshot while the callback consumes it. Export credentials
are rechecked after acquiring the snapshot lock. The transaction has a 60-second
timeout; slow readers hold a database connection and can delay repository writes.
Snapshot validation uses `Atoll.MST.Traversal.stream/3` to read the stored signed
tree without rebuilding it or retaining a complete record map. Canonical nodes
are checked with the same node validator used by individual proofs: CID hashes,
encoding, prefix compression, strict key ranges, hash-derived levels and required
intermediate nodes. Every signed record entry is compared with the database index
in bytewise order using a 128-row cursor. Missing/extra index entries, wrong CIDs
and corrupt stored nodes reject the snapshot before the consumer sends headers.
The previous ability to reconstruct a missing stored node from the index is not
used by streamed exports.

Traversal retains pending branches, with defaults of 129 levels, 100,000 nodes,
1,000,000 records and a 16 MiB metadata accounting budget. Each node is limited to
1 MiB and 10,000 entries. The accounting budget charges serialized node bytes,
expanded key bytes and a fixed per-entry allowance; it is not an exact BEAM heap
measurement. Completed branches release their charge, so total tree size need not
fit this budget. Trusted internal callers can adjust traversal count/accounting
limits; malformed or over-budget traversal raises `Atoll.MST.TraversalError`.

After validation, delivery walks the nodes again and streams distinct record CIDs
and bodies from PostgreSQL one row at a time. Incremental exports pin the selected
revision and query membership in PostgreSQL instead of loading its entire block
array into application memory. This adds node reads and, for incremental exports,
membership queries; normalized per-revision membership and higher-throughput
traversal remain possible optimizations. Full exports still inspect all metadata
before sending, and large repositories can reach the transaction deadline.

The complete archive, record/CID map and whole MST are not accumulated by this
HTTP export path. The buffered `Repositories.export/3` API consumes the same
validated stream, rejecting archives above 64 MiB or 100,000 block sections while
collecting chunks. It retains the encoded output but does not reconstruct a whole
MST, record map or revision membership set. Its CAR now uses the stream's block
order (commit first), and corrupt stored nodes fail rather than being rebuilt from
the record index. Lazy corruption becomes an error result without returning partial
bytes. Legacy buffered snapshot/MST APIs retain the metadata costs described above. The streaming callback must finish
consuming the enumerable before returning. The legacy `CAR.decode/1` and `import_archive/3` APIs remain buffered;
HTTP imports use incremental decoding and staging. Tests compare full and incremental block sets with the buffered codec,
exercise cancellation/corruption, and stream a repository larger than 64 MiB.

### Incremental CAR decoding

`Atoll.CAR.Decoder` accepts arbitrary binary chunks through `feed/4`, emitting a
validated header followed by hash-verified blocks to a synchronous callback. The
callback returns `{:cont, accumulator}` to continue or `{:halt, accumulator}` to
cancel. A partial varint or section is retained between calls. `finish/1` must
succeed at end of input; otherwise the archive is truncated. Duplicate blocks are
emitted and counted, leaving deduplication to the consumer.

The decoder buffers one section in 4 KiB segments: headers are limited to 64 KiB
and block sections to 2 MiB. Fragmented input never requires rebuilding the full
section on each feed. Default archive limits are 1 GiB and 1,000,000 block sections;
`new/1` accepts explicit `max_bytes` and `max_blocks` limits. Input validation and
consumer cancellation stop processing immediately. Tests cover every split point
in a sample CAR, byte-at-a-time input, malformed/truncated framing, hash failures,
limits, cancellation, and decoding over 64 MiB without accumulating output.

Callbacks can observe valid blocks before a later archive error. Import consumers
must stage those blocks and publish nothing until final framing, repository
signature, MST completeness, ownership, and quota validation all succeed. This
codec performs no database writes and does not authenticate repositories. Public HTTP imports use this decoder through private staging before
transactional publication.

### Private CAR staging

`Atoll.CAR.Stage.with_chunks/3` consumes an enumerable of binary chunks with the
incremental decoder, writing each unique verified block to a request-private
temporary file. A second private file stores its CID-to-offset/length index;
only roots, decoder buffers and fixed index metadata remain in application memory. The consuming callback is invoked only after
`Decoder.finish/1` succeeds. `Stage.read/2` reads and rechecks a staged block's hash
while inside that callback. Duplicate sections still count against decoder limits
but do not consume additional staging space.

`StageIndex` uses 48-byte slots containing a CID, byte offset and length. The
index reserves two slots per permitted block section (96,000,000 logical bytes at
the default million-section limit). Sparse-file support can reduce physical disk
allocation; capacity planning must allow the full logical size plus block bodies.
Each upload gets a random HMAC-SHA256 key to prevent clients from preparing a
chosen collision cluster. Linear probing wraps at the end of the file and stops
after at most 128 slot reads. Probe exhaustion or index I/O failure rejects staging;
it never falls back to an unbounded scan or in-memory map. Reads reject invalid
slots, out-of-range offsets/lengths, and bytes that fail the requested CID hash.
Duplicate blocks occupy one data/index entry but count toward the decoder limit.

The random staging directory has mode 0700 and is removed, with both files closed,
after normal return, invalid/truncated input, limit rejection, or exceptions.
No data is inserted into public block storage. Disk/creation failures produce a
staging error. Callers can choose a trusted `directory` and decoder byte/block
limits; defaults use the system temporary directory and the decoder's 1 GiB /
1,000,000-section limits. These options must not come from client request input.
A VM or host crash can leave private temporary files behind, so operational
stale-file cleanup and disk-capacity planning remain necessary when operating public
streaming imports. This stage validates transport integrity only;
repository signatures, complete MST membership, account authorization, and quotas
must still pass before publication. Public HTTP imports now use this staging path.

`Atoll.Repositories.Snapshot.from_stage/4` validates a staged repository using the
same signature, five-minute future-revision bound, bounded canonical MST traversal,
complete reachable-block membership, and record data-model checks as the buffered
snapshot decoder. It returns repository metadata, replayable record and reachable
CID streams, and a `read_block` callback instead of maps of records or block bodies.
Unreferenced staged blocks are omitted; shared record CIDs can occur repeatedly
in the CID stream and are deduplicated during revision staging. Records are checked individually
against the 1,000,000-byte limit and their collection's `$type`.

The callback remains valid only inside `Stage.with_chunks/3`; publishing imports
must finish all staged reads there. Validation does not retain a reconstructed
MST, record map or in-memory staging index. This validator does not publish
blocks or update accounts, blob references, quotas, or event streams. The HTTP importer uses this validator before staged publication.

`Atoll.Repositories.import_staged/3` publishes a stage inside its owning callback.
It authenticates the management session, validates the staged snapshot, then
rechecks authorization and the captured repository head/key under the normal
mutation locks. Record bodies are read individually for blob-reference indexing
and block insertion. Records, retained-revision membership, quota enforcement,
and the sync event commit atomically; a failure rolls them all back. Only reachable
blocks are inserted. Identical retries remain idempotent.

Migration imports retain their existing policy: a deactivated account may validate
against its recorded source key and re-sign with the local repository key. The
source commit is replaced in the published block set, while its CID/revision are
retained in migration metadata. The destination stays deactivated. Tests cover
staged publication, unreachable-block exclusion, quota rollback including blob
references, and cross-curve migration re-signing/retries. Public HTTP imports now use a stateful bounded reader with
`Stage.with_reader/4`, retaining the updated connection through completion or
failure. Tests include an HTTP upload larger than 64 MiB with duplicate sections.


Staging files are owned by temporary supervised lease processes that monitor their
request owner. If the request crashes or is killed, the lease closes the file and
removes its private directory. Normal completion explicitly releases the lease;
it is not restarted after owner termination. `ATOLL_IMPORT_CONCURRENCY` sets the
maximum simultaneous staging leases per node (default 16, range 1–64). Admission
failure maps to HTTP 503 before reading the body. This bounds concurrent staging
reservations locally; it is independent of Redis/PostgreSQL request budgets and
does not reserve actual free disk space. With the 1 GiB per-upload cap, plan disk
capacity for the configured concurrency as well as metadata and filesystem overhead.
VM/host crashes or abrupt termination of a lease itself still require stale-file
cleanup. Tests kill a request process and await lease termination to verify cleanup,
and verify rejection/re-admission at the concurrency limit without sleeps.

