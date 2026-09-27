# Administration and moderation

Operator endpoints, takedowns, account controls, and the audit history.

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
- `app.bsky.actor.getPreferences` (personal details stay full-session only).

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

### Administrative account search

`GET com.atproto.admin.searchAccounts` returns `{ "accounts": [...] }` and an
optional continuation `cursor`. `limit` defaults to 50 and accepts 1–100. Optional
`email` matches a complete normalized email address exactly, without wildcard or
substring matching. Results are ordered by DID and include inactive accounts and
pending signup profiles; repositories without account profiles are omitted.

Results contain account summaries with available email metadata and invitation
controls. Invite histories are omitted; use `getAccountInfo` or `getAccountInfos`
for those. The route requires operator Basic authentication before query parsing,
shares the admin rate limit, and returns `no-store`. Each page uses one database
query with one-second lock and five-second statement timeouts.

Cursors are bound to the normalized email filter and continue after the last DID,
even if that account has since been deleted. They are unsigned pagination markers,
not authorization credentials. Pages do not share a database snapshot; concurrent
insertions or email changes can change membership between requests.

### Operator handle updates

`POST com.atproto.admin.updateAccountHandle` accepts JSON `did` and `handle`, with
the separate operator Basic credential. It returns an empty 200 response. The
route authenticates before body parsing, applies the shared admin request budget
and 16 KiB body limit, and returns `no-store`.

Handle normalization, uniqueness, durable reservations, and fresh identity checks
use the same workflow as `com.atproto.identity.updateHandle`. For PLC identities,
Atoll signs a handle-only successor using its retained PLC authority key, publishes
the persisted operation, verifies the directory head, then updates the profile and
emits an identity event. Ambiguous publication retains the old local handle and
reservation; retry the same DID and handle to finish that operation. Different
pending operations must be resolved separately.

For `did:web`, the owner must first update the DID document. Atoll verifies the new
handle, unchanged repository signing key, and local PDS service before reconciling
the profile. Custom handles require a fresh forward claim to the same DID; operator
credentials do not bypass identity proof or let an account take an occupied name.

Operators can update active, deactivated, suspended, or taken-down accounts without
changing their availability or issuing sessions. Pending signup registrations are
rejected to preserve their reserved genesis identity. Owner requests continue to
require a live full session and an active account.

Successful local operator changes atomically record old/new handles in the private
audit history alongside the profile, observation, identity event, and PLC journal
completion. Verified unchanged requests are also audited without a duplicate
identity event. Failed or ambiguous publication has no success audit entry; its
signed operation remains in the durable PLC journal for reconciliation.

### Operator directory signing-key updates

`POST /xrpc/com.atproto.admin.updateAccountSigningKey` accepts exactly `did` and
`signingKey`, where the account is a local `did:plc` identity and the public key is
a canonical secp256k1 or P-256 `did:key`. The separate operator Basic credential
is required before JSON parsing. The route shares the admin 16 KiB body limit,
request budget and `no-store` policy, and returns an empty HTTP 200 on success.
The [upstream endpoint contract](https://github.com/bluesky-social/atproto/blob/7a857989751ae31518509d69ab7194a922064f3d/lexicons/com/atproto/admin/updateAccountSigningKey.json)
updates the DID document's public signing key.

Atoll verifies fresh PLC audit history and the latest directory head, changes only
`verificationMethods.atproto`, and signs with its retained PLC authority key.
Other verification methods, services, handles and rotation authorities are
preserved. The exact signed successor and an audit intent are committed together
before any directory POST. A failed intent audit prevents publication. Matching
readback and a fresh verified audit are required before completion; the completion
audit, durable journal completion and identity event are atomic. The identity
event omits the optional handle, prompting consumers to resolve the DID afresh.

Retry an ambiguous request with the same DID and public key. The stored operation
is reused and an already accepted operation is not posted again. A different
pending key or a pending owner/key-rotation workflow returns a conflict; generic
submission and active-update reconciliation cannot take over this intent. If the
directory advances away from the exact accepted head, the journal stays pending
for operator review. After review, `mix atoll.plc.reconcile_directory_key DID
PENDING_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID` completes the intent when the
accepted operation survives un-nullified in fresh verified audit history, the
reviewed head is current and the head still targets the requested key. It never
posts to the directory, re-signs, or touches private custody; the operator-actor
completion audit records the observed head, and the journal completion plus
identity event are atomic and idempotent. Any other state — nullified or replaced
operations, a moved head, or a head carrying a different key — is a conflict and
leaves the journal pending. Never delete or re-sign an unresolved journal. Requests for
the key already present in a verified current directory document are audited as
unchanged and do not emit another identity event.

This action changes directory metadata. It does not install or generate a local
repository private key, rotate repository commits, issue/revoke sessions, or
change account availability. If the supplied public key differs from Atoll's
local repository key, account status reports a DID-key mismatch and downstream
verification of local signatures against the new DID key fails. Coordinate this
operation with migration/key custody; use the existing staged repository-key
rotation workflow when rotating a locally hosted repository. Inactive completed
accounts are supported; pending signups are rejected. `did:web` documents remain
externally managed and this PLC publication endpoint rejects them. Run the
migration adding the dedicated directory-update journal marker before use.

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


