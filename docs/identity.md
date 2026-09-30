# Identity

DID and handle resolution, PLC submission and journals, and identity change flows.

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


### Owner-requested identity refresh

`POST com.atproto.identity.refreshIdentity` takes a full password-session access
token or a DPoP-bound OAuth token with base `atproto` scope, and JSON `identifier`
containing the account's DID or a handle resolving to that DID.
Atoll restricts this endpoint to the requesting account; app passwords and
taken-down export tokens cannot use it. OAuth requires an active account; password
sessions also support deactivated accounts. Refreshing another DID returns `Forbidden`.

The response contains `did`, the bidirectionally verified `handle` (or
`handle.invalid`), and the complete `didDoc`. DID lookup bypasses and refreshes the
node-local cache. DNS/HTTPS resolution retains the existing public-address checks,
timeouts and response limits. DID redirects are rejected; handle redirects follow
the bounded HTTPS policy described below. Missing identities return
`DidNotFound` or `HandleNotFound`; confirmed PLC tombstones return `DidDeactivated`.
Resolution failures and tombstones preserve the previous
observation and return an error. PLC-log verification follows the configured
resolution policy.

Resolution runs outside database locks. Before storing the observation, Atoll
rechecks the live session and account availability under the repository/event lock
order. OAuth also rechecks the current access token and grant, expiry and base scope;
proof admission precedes JSON parsing and stays consumed after a failed refresh.
Revocation during resolution prevents publication. Observation changes and
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

A missing DID or handle returns `DidNotFound` or `HandleNotFound`. PLC directory
HTTP 410 responses and surviving signed tombstones in audit mode return
`DidDeactivated`, as specified by the [identity Lexicons](https://github.com/bluesky-social/atproto/tree/main/lexicons/com/atproto/identity).
This distinction applies to `resolveDid`, `resolveIdentity`, and owner-authenticated
`refreshIdentity`. An HTTP 410 from did:web, an audit-log fetch, a handle lookup or
an OAuth/Lexicon endpoint does not prove a PLC tombstone and remains a resolution
failure. Responses do not include upstream response bodies. Invalid documents
and upstream failures return `InvalidRequest` without upstream response bodies.
Audit mode independently verifies the operation log before deriving the DID
document or reporting a tombstone.

All three public identity queries (`resolveDid`, `resolveIdentity`, `resolveHandle`)
share a per-node limit of 60 requests per five minutes per direct client IP, return
no-store responses, and reject request bodies. Query parsing retains the existing
32 KiB bound and Lexicon parameter validation.

### Sharing a handle namespace

One handle domain can be served by more than one PDS — `*.bsky.social` works
this way — because handle resolution belongs to whichever server owns the
wildcard, not to whichever server stores the repository. That server answers
`/.well-known/atproto-did` for the whole namespace while the repositories live
wherever the DID documents say they do.

`ATOLL_HANDLE_DELEGATES` is a comma-separated list of sibling PDS origins. When a
handle in this server's namespace matches no local account, each delegate is
asked `com.atproto.identity.resolveHandle` in turn, and the first DID returned is
served as the handle's answer. The on-demand TLS ask endpoint consults the same
list, so a delegate's handle can also be issued a certificate here; without that
the name would fail the TLS handshake before resolution was ever attempted.

A delegate is trusted only to name a DID for a handle already inside this
namespace. The handle is checked against the hosted-handle rules first, a
delegate's answer must be a syntactically valid `did:plc` or `did:web`, and
requests fail fast — two seconds to connect, three to answer — because the ask
endpoint runs on the TLS handshake path. A local account always wins: delegates
are consulted only when this server has no account for the handle.

Two servers may name each other, so a request sent to a delegate carries an
`atoll-delegate-hop` header, and a resolution request that arrives with it is
answered from local records alone. Without that stop, a handle nobody holds is
passed back and forth between them, each hop asking every other delegate, until
every hop's timeout expires — enough traffic to exhaust a small server.

Allocation asks them too. A hosted handle would otherwise be free to hand out on
the strength of owning the domain, which stops being true once a delegate issues
names in the same namespace, so account creation and any move onto a hosted
handle ask the delegates first and refuse a name another DID already holds with
`HandleNotAvailable`. Only an answered claim counts as taken: a delegate that
cannot be reached leaves the name unproven and registration proceeds, so an
outage there cannot stop signups here. With no delegates configured nothing is
asked and nothing changes.

This closes the allocation race only between servers that perform the check. A
delegate that allocates without asking in return can still issue a name this
server has already given out, so a shared namespace wants the check on both
sides.

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
Operator did:web and ordinary PLC repository signing-key rotation are available below; recovery remains pending.


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
A surviving tombstone resolves as `did_deactivated`; a properly recovered tombstone
can resolve normally. Invalid logs become `invalid_did_document`. The ordinary
ATProto key/PDS extraction and bidirectional handle checks still apply afterward.
Ordinary lookups may use an unexpired
positive cache entry; forced refresh bypasses it and evicts it when a tombstone
is observed. Deactivation errors are not cached, allowing subsequent recovery to
resolve without a negative-cache delay. Directory mode distinguishes the PLC
[document endpoint's HTTP 410 response](https://github.com/did-method-plc/did-method-plc/blob/main/website/spec/plc-server-openapi3.yaml)
from HTTP 404; audit mode requires the surviving tombstone's verified signature
and history, with no fallback to the directory's rendered document.

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
local profiles, repository signing keys, or session state. Authenticated handle changes and operator key rotation use this transport.
Recovery has a separate journal and submission path described below; operator
recovery reconciliation remains pending. Behavior follows the
[PLC update specification](https://web.plc.directory/spec/v0.1/did-plc).


### Durable PLC update journal

Migration `20260926154349` adds `plc_updates`. Internal
`Atoll.Identity.PLC.Updates.stage/3` verifies a supplied audit log back to the DID's
genesis, then verifies the proposed ordinary update against its surviving latest
operation. It stores the exact signed operation and trusted predecessor under the
repository lock. Only one locally incomplete update per DID is allowed; identical
staging retries return the same journal entry. Tombstones and recovery forks are
not staged by this workflow.

`submit/3` must run after the staging transaction commits. It uses the persisted
operation and records the first exact directory confirmation. Transport failures
leave the entry pending. Once confirmed, further calls return the stored historical
confirmation without posting again. Confirmation is not proof that the operation
is still latest after subsequent directory changes or recovery.

The future authorized workflow must commit its local profile/key changes together
with `complete!/2` inside one transaction. Completion requires confirmation and
releases the pending slot; both completion and local changes roll back together.
The journal itself changes no account status, profile, key, or session. Its callers
must authorize the action and verify any current identity conditions needed for
local activation. Supplied audit evidence proves signatures and chain consistency,
not freshness or completeness of the directory's history.

Include the journal in database backups. Account deletion cascades local entries;
it does not undo a public directory operation, including a submission already in
flight. Never discard an ambiguously submitted pending operation or generate a
replacement signature merely to retry. No automatic submission worker or public
identity-mutation endpoint is enabled by this internal foundation.


### Directory evidence for identity changes

`Atoll.Identity.PLC.Client.fetch_audit/2` reads `/log/audit` from the configured
trusted PLC directory, verifies its signatures, genesis binding, recovery rules,
and nullification flags, then compares the verified surviving head with a separate
fresh `/log/last` read. It returns both the entries and verified state; mismatched
heads fail with `plc_conflict`. There is no cache, redirect following, automatic
retry, or fallback to an unverified document. Audit responses are limited to 8 MiB
and 1000 operations; the latest-operation response retains the 64 KiB limit.
Encoded responses are rejected. Tombstone state is returned explicitly for callers
to handle; update staging refuses it.

`Updates.stage_from_directory/3` connects this lookup to durable staging. It refuses
an open local transaction so network waits cannot hold local mutation locks.
Workflows needing atomic local reservations can instead fetch evidence first and
call `stage/3` in their authorized reservation transaction. User authorization is
still the workflow's responsibility. The final submission checks the predecessor
again because the directory can change after evidence is read.

These two reads detect inconsistent snapshots, including a truncated audit that
omits the separately reported latest operation. They cannot prove completeness
against a directory withholding both views, authenticate its unsigned timestamps,
or prevent changes after either response. Public DID resolution retains its own
fixed-directory policy; this configured-directory lookup is for internal identity
mutation workflows.


### Handle-change reservations and completion

Migration `20260926155031` adds durable handle reservations linked to their exact PLC
journal operation. `Atoll.Identity.HandleChanges.stage/5` authorizes an active
account's full access session, validates a signed handle-only update against verified
audit evidence and the locally hosted signing key/service, and reserves the target
name in the same transaction as the journal entry. Other identity fields must remain
unchanged. The new operation uses a single `at://` alias. This currently accepts
modern and legacy PLC predecessors; legacy keys can be installed with the operator command below. did:web accounts use
the separate document-reconciliation path below.

Hosted names use the configured server domains. Custom names must freshly resolve
to the owner's DID. Authorization is checked again under the account lock after
network resolution. App passwords and inactive accounts cannot stage changes.
Signup and migration check both current profile handles and reservations under the
shared event lock, so another account cannot claim a pending target. The old profile
and hosted handle response remain in place while submission is pending.

After directory submission is confirmed, `complete/3` fetches a fresh verified audit
and requires the exact reserved operation to be latest. It rechecks custom-handle
ownership, session authorization, and the local key/service before atomically updating
the profile and identity observation, emitting one identity event, completing the
journal, and releasing the reservation. Repeating a completed operation emits no
second event. Conflicts retain the reservation and previous local handle for explicit
reconciliation. Account deletion cascades reservations; it does not undo public PLC
history. Existing resolver caches can retain old observations until their configured
TTL; authorization lookups force refresh.

The public `updateHandle` procedure now orchestrates these functions and signs with
the retained rotation key. Conflict recovery and other DID mutation workflows remain
pending. No real directory updates were submitted during tests.


### Public handle updates

`POST /xrpc/com.atproto.identity.updateHandle` accepts a full active-account access
token and JSON `{"handle":"new.example.com"}`. Success returns HTTP 200 with an
empty body, following the [endpoint Lexicon](https://github.com/bluesky-social/atproto/blob/7a857989751ae31518509d69ab7194a922064f3d/lexicons/com/atproto/identity/updateHandle.json).
Names are normalized to lowercase. Requests have a 4 KiB JSON limit and share the
20-per-five-minute login/identity-mutation IP budget. App-password sessions are denied.

New changes obtain fresh verified PLC history, verify local hosting/key continuity,
sign with the encrypted retained rotation key, reserve the name and signed operation,
submit, then perform the fresh completion checks described above. The retained key
must still be authorized by the directory's current rotation-key list. Custom handles
must resolve forward to this DID both before staging and before completion. Hosted
handles use the advertised server domains. The old hosted name stops resolving when
the new profile is committed.

After a timeout or HTTP 503, retry the same handle: the reservation selects the exact
persisted signed operation instead of creating a new signature. A different requested
handle while one is pending returns HTTP 409. Repeating an already completed current
handle checks fresh directory state and is a no-op, with no extra directory POST or
identity event. A directory conflict leaves local state pending for reconciliation.

This supports modern PLC accounts whose rotation key is retained by Atoll. Legacy
predecessors can now be converted into modern updates, with operator-installed
rotation keys. Operator retained-key replacement and authority rotation are
available below; operator recovery remains pending. did:web owners use the
reconciliation path below. Current configured directory/key availability is required;
local confirmation history never substitutes for fresh completion checks. No live
PLC writes are exercised by the test suite.


### did:web handle reconciliation

For a hosted did:web account, `updateHandle` reconciles a DID document the owner has
already updated. Publish the new `at://` handle in the document's first recognized
handle alias, retaining the account's current repository signing key and this PDS's
service URL, then call the same authenticated procedure. The existing resolver
supports hostname-level did:web identities, not path-based identifiers.

Atoll forces a fresh DID-document lookup through its existing bounded, address-pinned
HTTPS resolver. Custom handles must freshly resolve forward to that DID; hosted
names must be available under the configured domains. It checks the signing key,
PDS URL, active status, and full session again under the repository lock before
changing the profile and identity observation and emitting one identity event.
Current names and pending PLC handle reservations are both protected against takeover.
A concurrent local handle/observation change invalidates stale completion. Repeating
the current verified handle is a no-op.

This path does not write the externally hosted DID document and sends no PLC requests.
A mismatched document or failed lookup leaves the local account unchanged. As with
other identity resolution, the document can change after the lookup; later identity
refresh detects subsequent remote changes. App passwords cannot authorize this action.


### Legacy PLC successors

`Operation.successor/1` prepares a modern unsigned update from an already trusted
modern or legacy predecessor. For legacy `create` operations it maps `signingKey`
to `verificationMethods.atproto`, normalizes the handle alias and service endpoint,
and preserves rotation authority as recovery key first, signing key second (with
duplicates removed). Its `prev` is the CID of the original signed legacy operation;
it does not replace that genesis or derive a new DID. This follows the
[PLC legacy operation format](https://web.plc.directory/spec/v0.1/did-plc).

Handle-only staging and completion now accept this conversion while still checking
the local signing key, service, exact predecessor, owner session, and signed update.
The builder itself does not authenticate a chain; callers must verify audit evidence
before trusting a predecessor. Tombstones cannot be extended.

Tests cover upstream legacy fixtures and a signed legacy-to-modern handle change
through the journal and atomic local completion. Fresh signup still creates modern
operations. Retained keys for imported legacy accounts can now be installed through the operator
command below; no private key is inferred from public history.


### PLC signing authorization email

`POST /xrpc/com.atproto.identity.requestPlcOperationSignature` takes a full password-session
access token or an OAuth token with `identity:*`, and no body. It requires a PLC account with a confirmed email, and sends the
code exclusively through the configured Cloudflare email Worker. Active accounts
and user-deactivated accounts using password sessions can request it; app passwords, suspended/taken-down
accounts, and unsupported DID methods cannot. The endpoint returns empty HTTP 200
only after Worker acceptance. A persistent one-minute cooldown limits issuance.

Migration `20260926160604` adds a redacted purpose/DID/address-bound SHA-256 digest,
expiry, and request timestamp to the account profile. Codes contain 192 bits of
randomness and expire after 15 minutes. A new request replaces the previous code.
Worker failure leaves the cooldown and pending challenge intact; there is no
automatic retry or SMTP fallback. Email changes, password resets, and operator
password/email changes invalidate these challenges alongside existing account codes.

`SignatureChallenges.consume!/2` is the internal signing-transaction boundary: it
rechecks current session or OAuth identity authorization and confirmed email, verifies expiry and the
digest, and clears the token atomically. Signing failure must roll back the same
transaction, preserving the authorization for retry. The public `signPlcOperation` endpoint now consumes these codes;
`submitPlcOperation` is available for operations matching this local account. Requesting a code does not itself sign or
submit a PLC operation.


### Email-authorized PLC signing

`POST /xrpc/com.atproto.identity.signPlcOperation` requires a full active or
user-deactivated password session, or an active OAuth session with `identity:*`,
and the current email code in `token`. Optional
`rotationKeys`, `alsoKnownAs`, `verificationMethods`, and `services` replace the
corresponding fields of the fresh verified predecessor; omitted fields are preserved.
Callers cannot supply `prev`, `sig`, `type`, or another DID. It returns
`{"operation": {...}}`, following the
[pinned endpoint Lexicon](https://github.com/bluesky-social/atproto/blob/7a857989751ae31518509d69ab7194a922064f3d/lexicons/com/atproto/identity/signPlcOperation.json).

Atoll verifies the email authorization before directory lookup, checks the audit
head against `/log/last`, and then consumes the code and signs in one local transaction.
The current DID signing key and PDS service must still match this hosted repository.
Its retained rotation key must be authorized by the predecessor. A pending journaled
identity update blocks another signature. Authorization, email state, and session
revocation are rechecked under locks after network lookup. Invalid operations or
signing failures roll back code consumption.

The JSON envelope is limited to 16 KiB; canonical signed operations remain bounded
to 7500 bytes and new rotation-key lists to one through five distinct supported keys.
The endpoint shares the 20-per-five-minute identity/login IP budget. It returns the
signature without posting to the directory, changing local keys/profiles, or emitting
an event. Owners can use the operation for migration or rotation through a separate
submission workflow. Directory changes after lookup can make its predecessor stale.

A successful response consumes the code once. If the response is lost after commit,
request a new code after the cooldown; there is no signed-response replay cache.
Keep the returned signed operation unchanged when submitting or retrying it. Public submission is available for operations matching the local account;
operator signing-key transition workflows are described below; local recovery
reconciliation remains pending.


### Authenticated PLC submission

`POST /xrpc/com.atproto.identity.submitPlcOperation` accepts a full active or
user-deactivated account session and `{"operation": {...}}`. Its 16 KiB JSON envelope
and 20-per-five-minute identity/login IP budget match signing. It returns empty
HTTP 200 after directory confirmation and local reconciliation, following the
[pinned submission Lexicon](https://github.com/bluesky-social/atproto/blob/7a857989751ae31518509d69ab7194a922064f3d/lexicons/com/atproto/identity/submitPlcOperation.json).

The signed modern operation must name this PDS, the local repository signing key,
and the profile's single `at://` handle alias. The corresponding private repository
key must be available locally. Custom handles require fresh forward ownership;
hosted names use the configured domains. New operations require one through five
distinct supported rotation keys. Tombstones, arbitrary handle changes, and operations
pointing away from this local account are rejected. This endpoint can receive an
externally signed migration operation; it does not require the destination PDS to
possess the identity's rotation key or another email code.

Atoll verifies fresh audit evidence and predecessor authorization, durably stages
the exact operation under the owner lock, rechecks the session before sending,
confirms directory acceptance, and verifies fresh directory state again before
completing the journal and emitting one identity event. Local profile, repository
key, and active/deactivated status remain unchanged. A migrated account still needs
explicit activation after its other migration requirements are satisfied.

Retry the identical operation after ambiguous errors. A matching accepted latest
operation is confirmed without reposting, including acceptance before local staging.
That case derives its predecessor from the fully verified surviving audit chain;
nullified historical forks are not accepted as ordinary updates. Pending handle
changes must finish through their own workflow. Directory conflicts preserve the
pending journal for reconciliation. Completed retries emit no additional event.
No real PLC submissions were made in tests.


