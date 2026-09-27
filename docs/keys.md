# Key custody and recovery

Encrypted signing-key custody, rotation workflows, PLC recovery, and pending-work reconciliation.

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
   Also run `mix atoll.keys.rewrap_reserved --limit 100` through all pages, using
   `--after DID_KEY` for its public-key cursor, to cover keys reserved before account creation.
4. Repeat a complete pass from the beginning to verify every envelope is readable
   with the active key; it should report zero rewrapped envelopes. Remove the old
   fallback from every node only after the complete successful pass. Keep old keys
   securely available for backups made before the rotation.

Each page scans at most 100 repositories in DID order and commits atomically.
Output contains only `scanned`, `repositories`, `plc`, and `totp` rewrap counts, `unchanged`
envelope count, and an optional DID cursor. Repositories without stored envelopes
are counted as scanned but need no change. An unreadable/tampered envelope or
database failure aborts the entire page; repair and retry that page without
skipping the affected account. The command is resumable and idempotent.

Rewrapping takes the event lock followed by repository and envelope locks, with
bounded lock/statement waits. It preserves the authenticated envelope binding,
private/public signing-key material, repository commits, signed PLC operation,
registration state, sessions, and public events. Both repository keys and retained
PLC rotation keys, plus pending replacement repository keys, must migrate before
retiring an old master key. Pending-key rewraps are included in the `plc` count.
Reserved keys have no repository yet and are covered by the separate
`rewrap_reserved` command, which reports `scanned`, `rotated`, `unchanged`, and an
optional public-key cursor. Verify a complete pass of both commands before
retiring a fallback key.

Each successful page, including unchanged or empty pages, appends an operator audit
entry atomically with its envelope updates: `atoll.keys.rewrap` or
`atoll.keys.rewrapReserved`. Entries retain the page limit, input/output cursors,
at most 100 scanned public identifiers (DIDs or reserved public keys), and result
counts. They never retain master keys, private keys, authenticator secrets,
envelopes, or key fingerprints. Audit insertion failure rolls back the entire
page. Inspect these server-wide entries using `mix atoll.moderation.history`
without a DID filter.

This rotates encryption protection, not repository signing keys, PLC authority,
JWT secrets, or server identity keys. It cannot recover an envelope when every
key capable of decrypting it has been lost. No rotation is scheduled automatically.

### Reserved signing-key custody

The internal `Atoll.Accounts.SigningKeyReservations` coordinator persists secp256k1
keys before a repository exists. `POST /xrpc/com.atproto.server.reserveSigningKey`
accepts JSON `{}` or `{"did":"did:plc:..."}` without authentication and returns
`{"signingKey":"did:key:..."}`. It requires JSON, limits bodies to 4 KiB, returns
`no-store`, and shares the login/createAccount budget of 20 requests per IP per
five minutes. Reservation does not submit DID operations, create accounts, or
authorize migration.

Reserve with a DID before migration. After service-JWT authorization and handle
verification, `createAccount` atomically consumes that DID's reservation, installs
the exact key, and creates the deactivated account. The source signing key remains
pinned for repository import. Installation or session-creation failure rolls back
the reservation claim and service-token consumption. An unreadable reservation
fails instead of silently substituting a different key. Accounts without a
DID-bound reservation retain the existing generated-key migration flow.

Anonymous reservations return distinct public keys and retain encrypted custody.
To select one, include a signed `plcOp` successor in `createAccount` for an existing
PLC DID. This path still requires the source account's service JWT, password,
verified handle, and an invite when configured. It verifies fresh PLC history,
checks that the service JWT's signing key matches that history, and verifies the
successor's predecessor CID and authorized rotation-key signature. The operation
must advertise the requested handle, this PDS service, and the reserved key. A
DID-bound reservation can also be selected this way, but cannot be claimed by a
different DID. `did:web`, tombstones, genesis operations, and keys outside local
reserved custody are rejected for this path.

The account, encrypted destination key, source import key, credentials, invite use,
service-token consumption, and exact PLC journal entry commit together before any
directory POST. Atoll then uses the authenticated `submitPlcOperation` workflow to
publish and verify the operation. Success returns a session for the still-deactivated
account; repository/blob transfer and explicit activation remain separate steps.

If publication or final reconciliation fails after that commit, the response is
`503 MigrationPublicationPending`: **the account already exists**. Log in using
the supplied DID/password and submit the exact original operation through
`com.atproto.identity.submitPlcOperation`. Do not repeat `createAccount` or generate
a different operation. The reserved key has become account custody and the source
service token has been consumed; neither is undone after possible external
publication. Directory conflicts may require operator reconciliation. Validation
or provisioning failures before the commit retain the reservation and service
token for retry. Sessions minted before an unsuccessful publication response are
not returned and remain subject to the normal session expiration/cleanup policy.

Without `plcOp`, reserve with a DID and provision/transfer the account before changing
its public signing key and PDS service. Publishing the DID update first can
invalidate the source service JWT. `createAccount` retains its 4 KiB JSON body limit,
including the optional operation; this does not add entryway or passwordless signup.

`reserve/1` accepts an optional DID and returns only the public `did:key`. Repeating
a DID reservation returns the same usable key; reservations without a DID create
distinct keys. Existing local repositories cannot receive another reservation.
AES-256-GCM protects private material with a distinct purpose, optional DID, and
public key bound as authenticated data. Active and previous encryption master
keys follow the same custody policy as repository keys.

Creation is serialized through the database event lock and capped at 10,000
reservations. `ATOLL_RESERVED_SIGNING_KEY_LIMIT` (application configuration
`:reserved_signing_key_limit`) can lower this cap to 1–10,000. Existing DID reservations remain readable at the
cap. Reservations do not expire automatically because a public DID might already
reference one; exhaustion rejects new reservations rather than deleting custody.

`claim!/2` is an internal operation for a separately authorized account-creation
transaction. Its caller must independently prove the DID and select the expected
public key. It rejects a different DID binding or unreadable envelope, returns the
private key only to the trusted caller, and deletes the reservation in that same
transaction. Failed account/key installation must roll back the transaction to
retain the reservation. A public key alone is not migration authorization.

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

### Installing an imported PLC rotation key

An operator with the account owner's private rotation key can install it without
creating a signup registration record or submitting a directory operation:

```sh
mix atoll.plc.install_rotation_key did:plc:YOUR_DID /secure/path/rotation-key.json
```

The bounded JSON file contains `{"curve":"k256","privateKey":"BASE64_32_BYTES"}`;
`p256` is also supported. Protect the file with permissions such as `chmod 600` and
remove the temporary copy according to your key-handling policy. The command reads
at most 4096 bytes and prints only DID and installation status. It uses fresh verified
PLC audit evidence plus the latest-operation check to require that the supplied key
is currently authorized, preserving legacy recovery/signing-key authority rules.

Migration `20260926161910` adds a separate encrypted imported-key store. AES-256-GCM
binds the envelope to DID, curve, public key, and the verified operation CID. The
private scalar is never stored as plaintext in PostgreSQL; the envelope is redacted
from struct inspection and database calls suppress parameter logging. Back up this
table together with the master-key configuration. Account deletion cascades its row.

Imported keys take precedence over a retained signup key. Missing imported rows
fall back to signup storage; unreadable imported envelopes fail closed. An identical
installation is idempotent. Ordinary installation of a different key over an existing imported key
and installation during a pending journaled identity update are rejected. Explicit
replacement requires the expected-current-key option described below. This is a local
operator command, not an unauthenticated HTTP key-upload route or a key-rotation API.

The normal bounded master-key rewrap task now includes imported envelopes in its
`plc` count (counts are envelopes, potentially two per account). Rewrapping preserves
the private key and directory evidence. Later signing still verifies current directory
authority; a once-authorized key is not assumed to remain authorized forever. No real
account key was installed during implementation; tests used generated disposable keys.


### Replacing an installed rotation key

To replace an imported/installed key, provide its expected current public `did:key`:

```sh
mix atoll.plc.install_rotation_key did:plc:YOUR_DID /secure/path/new-key.json --replace did:key:EXPECTED_CURRENT_KEY
```

The replacement private key must already be authorized by fresh verified directory
history. Under the repository lock, Atoll compares the stored public key with the
expected value and rejects stale callers, missing installed rows, and pending local
identity updates. It then atomically stores a new encrypted envelope with the new
curve, public key, and verified directory CID. Ordinary installation still cannot
overwrite a different key. The option order shown above is required.

This changes which already-authorized key Atoll retains locally; it does not publish
a PLC key rotation, alter the repository signing key, or emit an identity event. It
can also repair a damaged envelope when the operator supplies the correct authorized
private key and expected public key. It does not recover a lost private key. Signup
registration evidence and its original envelope remain intact; the installed key
continues to take precedence. Replacement uses the active encryption master key.
Repository signing-key transitions and ordinary directory-authority rotation are
available below. Recovery submission primitives are available, with operator
reconciliation still pending.


### Rotation-key custody audit

Operator key installation and explicit replacement now append an audit entry in
the same database transaction as the key operation. Entries identify the account,
operation, expected public key when replacing, freshly observed directory operation
CID, result, and public before/after key metadata. Unchanged installation retries
are recorded too. Failed authorization, stale expected keys, and pending-update
rejections do not create successful-change entries. An audit insertion failure rolls
back the key mutation.

The actor is `operator`, distinct from shared HTTP `admin` credentials; it identifies
the local operator path, not an individually authenticated person. Entries never
include private scalars, encrypted envelopes, master keys, or key-file contents.
They remain in the private operator audit history after account deletion. As with
other audit entries, this is application-level history, not a tamper-proof database
ledger or a record of directory key rotation.


### Historical repository signing keys

Each retained repository revision now stores the public signing key and curve
used when that revision was published. Historical record-version reads and
`getBlocks` membership checks verify the revision's commit using those stored
values, then validate its MST and path/block membership. Current snapshot checks
continue to use the repository head's current pinned key. No private key material
is added to revision history.

Migration `20260926171507` backfills existing revisions from their repository's
pinned key and makes both fields required, with curve and compressed-key-length
constraints. This relies on the pre-migration invariant that Atoll has no repository
signing-key transition workflow and migration imports are re-signed locally.
Out-of-band manual key changes are not reconstructed by the migration. Invalid
historical key metadata fails verification rather than authorizing block access.
New revisions capture their key inside the repository publication transaction.

This prepares history for signing-key rotation; it does not itself rotate keys,
change DID documents, or enable a rotation endpoint. Tests model an atomic
cross-curve key transition and verify historical reads, historical block export,
and rejection after key-metadata corruption.

### Atomic local signing-key transitions

`Atoll.Repositories.rotate_signing_key/3` is an internal publication primitive,
not an authorization boundary or public rotation endpoint. Its caller must first
authorize the account and establish that the DID document authorizes the proposed
key. The function requires the expected repository head, validates the new private/
public key pair, verifies the current snapshot and decryptability of the existing
vault key under the normal mutation locks. It preserves active/deactivated
status and rejects other account states.

The transition replaces the encrypted vault envelope, signs a newer commit over
the unchanged MST, records revision-key provenance, and emits a sync event in one
transaction. Quota checks still apply; any failure rolls back the vault, head,
revision, blocks, and event. A same-key request against the current expected head
is an idempotent no-op. Subsequent managed writes use the new key, while historical
revisions remain verifiable with their recorded keys. This is not a recovery path
for an unreadable current vault.

The did:web and PLC operator commands below invoke this primitive after fresh
authority checks. PLC rotation retains encrypted pending custody across directory
submission and local publication failures. Tests exercise cross-curve replacement, continued writes,
historical reads, idempotence, deactivation, stale heads, invalid key pairs, vault
corruption, and quota rollback.

### Operator did:web signing-key rotation

After updating the external did:web document to authorize the replacement
`#atproto` key, run:

```sh
mix atoll.keys.rotate_web did:web:alice.example.com /secure/new-key.json did:key:CURRENT_PUBLIC_KEY
```

The private file must contain exactly `curve` (`k256` or `p256`) and `privateKey`
(standard base64 encoding of the 32-byte private key), and be at most 4 KiB.
Restrict its permissions to the operator and retain it securely until completion
is verified. Pass the currently installed public did:key as the final argument.
The command never changes the external DID document or submits PLC operations.

Fresh resolution must authorize the replacement key, name this PDS service, and
claim the existing local handle. Custom handles must resolve back to the DID.
The transaction rechecks the expected local key and detects intervening local
identity changes. It atomically replaces the encrypted key, publishes a newer
commit over the unchanged tree, emits identity then sync events, updates the
identity observation, and records an operator audit containing public keys and
commit identifiers only. Active and deactivated accounts are supported; other
states and unreadable existing vaults are rejected.

After success, retrying with the old expected key fails as stale. Supplying the
new current key and the same private file succeeds as unchanged without new
repository events (the attempt is still audited). Remote DID updates and local
publication cannot be one transaction: schedule an appropriate maintenance
window, and retry this command if local completion fails after the document
change. This is operator reconciliation, not automatic key recovery or a PLC
rotation workflow.

### Pending PLC signing-key custody

`Atoll.Identity.PLC.PendingSigningKeys.stage/5` is an internal staging primitive
for the remaining PLC rotation workflow. It checks the expected local signing
key, existing vault readability, the replacement private/public pair, and the
new public key named by a valid signed PLC update. The existing update journal
verifies the supplied audit chain. The caller must still authorize the operation
and obtain fresh directory evidence; this primitive does neither network IO nor
local key publication.

The signed update and encrypted replacement key are stored in one transaction.
AES-256-GCM authenticates the DID, operation CID, expected old public key, curve,
and new public key. Exact retries retain the same envelope; there is at most one
retained pending key per account. An ambiguous directory submission leaves that
key available for reconciliation. Master-key rewrapping covers pending custody
in the same atomic, paginated pass as other vault envelopes.

After verified directory acceptance and matching local key publication, callers
mark the journal completed and release pending custody in the same transaction.
Release verifies the installed key is readable and matches the replacement; it
erases only the pending encrypted private key, retaining public journal metadata.
Account deletion cascades the journal and its encrypted custody. The operator
workflow below supplies orchestration and fresh completion checks; recovery
remains pending.

### Operator PLC repository signing-key rotation

The server must retain a PLC rotation private key currently authorized by the
directory, either from signup or the operator rotation-key installation command.
This workflow changes only `verificationMethods.atproto`; directory rotation
authority, services, aliases, and other verification methods are preserved.
It implements ordinary successor updates under the
[PLC specification](https://web.plc.directory/spec/v0.1/did-plc), not recovery forks.

```sh
mix atoll.keys.rotate_plc stage did:plc:ACCOUNT CURRENT_PUBLIC_DID_KEY p256
mix atoll.keys.rotate_plc status did:plc:ACCOUNT
mix atoll.keys.rotate_plc resume did:plc:ACCOUNT STAGED_OPERATION_CID
```

For an accepted rotation whose directory head advanced before local completion:

```sh
mix atoll.keys.rotate_plc reconcile did:plc:ACCOUNT STAGED_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID
```

`reconcile` fetches fresh verified history and requires the exact reviewed head,
with the staged operation still in the active chain. The current identity must
advertise the staged replacement repository key, the same handle and local PDS
endpoint, and the staged authority list in the same order. Unrelated service
changes are allowed. It verifies forward handle ownership and rechecks local
profile, observation, current key, and readable custody under account locks.
Recovery and combined key workflows remain separate.

No directory POST occurs. Local completion uses the same repository transition as
`resume`: records remain unchanged, a new commit is signed by the retained key,
and identity then sync events are emitted. Confirmation, commit, key installation,
journal completion, pending-envelope erasure, observation, and an
`atoll.keys.reconcilePlc` audit all commit together. The audit includes the accepted
operation CID and observed current directory head. Quota or other publication
failures roll the whole transition back, preserving pending custody for retry.
Compatible completed retries do not create another commit, event, or audit.

`stage` accepts `k256` or `p256`, checks fresh verified directory history against
the expected local public key, PDS service and handle, verifies the forward
handle claim, and generates a new repository key. It atomically persists the
encrypted replacement and signed operation without directory submission or
changing the active key. It prints only public metadata including the operation
CID. A second stage while an update is pending fails; use `status` to recover the
existing CID instead. Status is local journal state, not a fresh directory check.

`resume` verifies fresh history before submitting the exact persisted operation
and again before completing the local transition. The operation must still be
the current directory head; historical acceptance alone is insufficient. Under
local mutation locks, it rechecks account state, current key, handle, and identity
observation. Identity and sync events, unchanged-tree commit publication, key
vault replacement, journal completion, pending-secret erasure, and an operator
audit of public keys/commits are committed together. Active and deactivated
accounts are supported, preserving their status. Completed retries emit no new
events or audits and still require current directory and local compatibility.

Directory acceptance and PostgreSQL publication cannot be atomic. Schedule a
maintenance window and securely back up the database and vault master key before
operating on production identities. If a timeout, quota failure, or process exit
interrupts completion, retry `resume` with the same CID; do not restage or delete
the pending journal. Matching directory acceptance avoids a second POST. A later
conflicting directory update leaves custody intact and fails closed, requiring
operator reconciliation; automatic recovery/rebasing is not implemented.

### Pending PLC directory-authority key custody

The internal `Atoll.Identity.PLC.PendingAuthorityKeys` API stages an encrypted
replacement for the retained PLC rotation key alongside its immutable signed
update. It requires an ordinary authority-only successor: the expected retained
key is replaced in its existing priority position, with all other rotation keys,
verification methods, aliases, and services unchanged. It does not perform
fresh network authorization or submit an operation; its caller must do so.

Custody uses a separate authenticated encryption domain from repository signing
keys, binding the DID, operation CID, expected authority key, curve, and new
public key. Exact retries preserve custody, and ambiguous delivery never removes
it. One retained authority envelope per account is enforced in PostgreSQL. Ordinary
updates permit one key purpose; verified recovery journals may retain both
repository and authority keys. The master-key
rewrap command includes pending authority envelopes in its `plc` count and aborts
the whole page if an envelope cannot be verified.

After fresh directory confirmation, callers can atomically adopt the key with
`RotationKeys.adopt_pending!/2`, complete the journal, and release pending custody.
Adoption verifies confirmation, account state, and the current retained key,
then installs encrypted custody in the retained-authority vault without changing
the repository signing key. The original signup envelope remains retained; the
installed replacement takes precedence for future PLC signing. This primitive
is not a fresh-authority check or an operator command. Generic account
`submitPlcOperation` cannot complete a journal carrying staged key custody.
The operator workflow below provides ordinary authority rotation; recovery
orchestration remains pending.

### Operator PLC directory-authority key rotation

Use the currently retained PLC authority public did:key as the expected key:

```sh
mix atoll.plc.rotate_authority stage did:plc:ACCOUNT EXPECTED_AUTHORITY_DID_KEY p256
mix atoll.plc.rotate_authority status did:plc:ACCOUNT
mix atoll.plc.rotate_authority resume did:plc:ACCOUNT STAGED_OPERATION_CID
```

If that rotation was accepted but the directory advanced before local installation,
review the new directory head and reconcile without another POST:

```sh
mix atoll.plc.rotate_authority reconcile did:plc:ACCOUNT STAGED_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID
```

Reconciliation verifies fresh active history containing the exact staged operation
and requires the expected current head. The latest operation must retain the
staged authority list in the same order, the local repository key, the same handle,
and this PDS endpoint. Unrelated service changes are allowed. Forward handle
verification, readable old authority/repository custody, and unchanged local
profile/observation checks still apply. Recovery and combined key workflows are
not accepted by this command.

Within the account transaction, reconciliation records confirmation if absent,
installs the retained replacement authority, completes the journal, releases its
pending envelope, and writes an `atoll.plc.reconcileAuthority` audit containing the
observed directory head. Installed authority metadata retains the accepted
rotation's CID. Account status, repository signing keys, records, and sessions do
not change; no stream event is emitted. Repeating the command with fresh compatible
evidence does not duplicate the audit or completion timestamp. Conflicting or stale
evidence leaves pending custody intact for review.

`stage` accepts `k256` or `p256` and generates the replacement inside the durable
staging transaction. Fresh verified directory history must authorize the
expected retained authority and match the local repository key, PDS service,
and bidirectionally verified handle. The operation replaces that one authority
in its existing priority position and preserves all other identity fields.
Only public metadata, including the CID and replacement public key, is printed.

`resume` checks fresh directory history before submission and again before local
completion. A matching current directory operation permits retries without a
second POST. Under mutation locks, completion rechecks the retained authority,
account status, repository key, handle and identity observation; installs the
encrypted replacement; completes the journal; erases pending custody; and adds
a private operator audit of public keys and operation CID. These local changes
commit atomically. Subsequent PLC signing uses the installed authority.

Authority keys are internal to PLC and do not appear in the resolved DID document.
This transition leaves the repository commit and key unchanged and emits no
repository or identity events. Completed retries still verify current authority
and local identity but create no duplicate audit. Active and deactivated
accounts are supported, preserving their status.

Back up the database and encryption master key before production rotation. The
new authority exists only in encrypted database custody; this command does not
export its private key. Directory acceptance and local installation cannot be
one transaction. After interruption, keep the journal and retry the same CID;
`status` recovers a pending CID but reports local state, not fresh directory
authority. A later conflicting directory operation fails closed with custody
retained. Recovery forks, arbitrary priority changes, and recovery-key export
are not implemented by this command.

### Signed PLC recovery preflight

`Atoll.Identity.PLC.RecoveryPlan.preview/4` validates an already signed recovery
operation against supplied audit evidence and a proposed UTC receipt time
(defaulting to the current time). It verifies the existing history, requires a
fork from a surviving ancestor, computes the active suffix that would be
nullified, and verifies the resulting hypothetical history with the existing
recovery-aware audit verifier. Ordinary successors, repeated operations, and
forks from nullified entries are rejected. At most 999 existing entries are
accepted so the hypothetical history stays within the 1,000-entry verifier cap.

The result contains public metadata: candidate CID, predecessor CID, observed
head CID, signer, newly displaced CIDs, deadline, and resulting tombstone status.
The higher-priority signature and 72-hour recovery window follow the
[PLC recovery rules](https://web.plc.directory/spec/v0.1/did-plc#key-rotation--account-recovery).
The deadline is computed from the first displaced operation, with the exact
boundary accepted and the following microsecond rejected. Previous
nullifications remain intact. A lower-priority tombstone can be displaced by a
valid recovery from its surviving ancestor.

`RecoveryPlan.from_directory/3` obtains fresh verified audit evidence and checks
its head against the directory's latest operation before previewing. It refuses
to perform network lookup within a database transaction. These are preflight
primitives: they do not authorize an operator, store or submit operations, or
change local identity. Directory timestamps and history completeness remain
trusted. A preview cannot reserve the window or guarantee acceptance after an
intervening operation; the directory uses its actual receipt time. The durable
recovery journal below builds on this preflight; local recovery reconciliation
remains pending.

### Durable PLC recovery journal and submission

`Atoll.Identity.PLC.Recoveries.stage/4` stores an already signed, preflighted
recovery operation, its fork predecessor, reviewed directory head, recovery
deadline and displaced operation CIDs. Staging uses the same account mutation
locks and single-pending-update constraint as ordinary PLC updates, and can be
combined with caller reservations in one transaction. Exact retries preserve
the row; changed review scope is rejected. This is an internal primitive: the
caller must authorize recovery and obtain fresh evidence before staging.

`Recoveries.submit/3` fetches fresh verified audit history before POST. The
current head, displaced suffix and deadline must match the staged review; it
never automatically rebases a recovery onto intervening operations. After POST,
including ambiguous failures, it checks fresh verified readback and reconstructs
the pre-recovery evidence to confirm the reviewed scope. A matching accepted
operation supports read-only retries, even after the recovery window has elapsed
provided directory receipt was within the reviewed window. Confirmation time is
recorded once and does not complete any local identity change.

The PLC API cannot atomically enforce Atoll's reviewed-head condition. An operation
may arrive between preflight and POST, and the directory might accept a fork
that invalidates more operations. Readback detects that mismatch and leaves the
journal unconfirmed for operator reconciliation; it cannot undo directory
acceptance. Expiry, rejection, conflicts and timeouts retain the exact staged
operation. Generic ordinary-update submission paths cannot complete recovery
journals. Account deletion cascades the journal. The operator command below
provides authorized staging and atomic local completion for restoring existing
local keys, with optional repository and PLC authority key replacement. Recovery
with conflicting pending work remains unfinished unless the pending operation
has been explicitly nullified, as handled by the reconciliation command below.

### Operator recovery of the current local identity

For a signed recovery that restores the existing local repository signing key,
handle, PDS service, and a retained readable PLC authority, run:

```sh
mix atoll.plc.recover stage did:plc:ACCOUNT signed-recovery.json
mix atoll.plc.recover status did:plc:ACCOUNT
mix atoll.plc.recover resume did:plc:ACCOUNT STAGED_OPERATION_CID
```

If recovery was accepted but the directory advanced before local reconciliation:

```sh
mix atoll.plc.recover reconcile did:plc:ACCOUNT STAGED_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID
```

This command verifies fresh full audit history, the exact expected current head,
and continued membership of the recovery CID in the active chain. It reconstructs
the audit prefix at recovery acceptance and verifies the originally reviewed head,
displaced CID list, and deadline. The deadline is checked at historical acceptance
time; the command does not extend the recovery window or expand the reviewed scope.
The latest identity must retain the recovery's authority list in the same order,
intended repository key, local PDS service, and profile handle. Unrelated service
changes are allowed. Forward ownership and local profile/observation checks remain
required.

No recovery POST occurs. One account transaction confirms historical acceptance,
restores any retained repository and/or authority keys, revokes old credentials,
publishes the identity and any required signed repository transition, completes the
journal, releases pending key envelopes, and records an
`atoll.plc.reconcileRecovery` audit with the observed directory head. Missing old
custody is handled only by the explicitly staged restoration contexts; this does
not weaken expected-key or absent-authority checks. Quota or custody failures roll
back the full local transition, including credential revocation. Completed retries
verify fresh compatible evidence without revoking newly issued credentials or
repeating events/audits. Incompatible, absent, or nullified recovery operations
remain for their respective reconciliation workflows.

The operation must already be signed by an authority allowed to recover from its
chosen surviving ancestor. The JSON file is bounded to 64 KiB, rejects duplicate
object keys and excessive nesting, and must pass the signed-operation and recovery
verifiers. The command never receives the external recovery private key. The
retained local PLC authority must be included in the recovered rotation-key list.
`stage` verifies fresh directory history, forward handle ownership and local key
readability before persisting the exact reviewed fork. It performs no POST.

`resume` rechecks local compatibility, uses verified recovery submission/readback,
and fetches fresh directory history again before local completion. Under account
locks, completion checks for intervening identity changes and atomically revokes
all local sessions and app passwords, clears pending account challenges, updates
the identity observation, emits an identity event, completes the journal, and
records an operator audit of public recovery scope and revocation counts. A
completed retry verifies directory/local compatibility and creates no duplicate
event, audit or revocation; sessions created after recovery remain usable.

The repository key and commit, account password, email, and account status are
preserved. Active and deactivated accounts are supported; suspended and taken-down
accounts require separate operator handling. This path assumes the retained local
keys are still trusted and readable. It does not repair compromised account
passwords/email, revoke service tokens already accepted by external services,
replace lost/private keys, or overwrite another pending PLC operation. Use the
existing password-management workflow when local credentials are compromised.
Repository-key replacement is supported by `stage-key` below; `stage-authority`
and `stage-keys` also restore PLC authority custody. Pending-operation conflict
reconciliation supports explicitly nullified history; other conflicts remain
unfinished. Missing authority metadata is supported with
an explicit `absent` expectation as described below.

Directory acceptance and local completion cannot be atomic. Keep the journal
after any interruption, and use `status` to recover its CID before retrying
`resume`. A conflict leaves the operation pending for reconciliation rather than
restaging or expanding its recovery scope. No email is sent by this command.

### Internal repository key restoration

`Atoll.Repositories.recover_signing_key/3` supplies the local publication primitive
for recovery when the prior repository vault envelope is missing, corrupt, or
unreadable under the available master keys. Its caller must independently
authorize recovery and freshly establish that the DID document authorizes the
supplied replacement key. The `stage-key` recovery workflow below invokes this
primitive after fresh directory confirmation; ordinary rotation still requires
readable old custody.

Restoration requires the expected current head and a valid private/public key
pair. Under normal event/account locks it verifies the current commit signature,
revision and MST root, then reads and hash-checks every referenced record body
before installing custody. Record bodies are checked one at a time; repository
metadata uses bounded traversal and PostgreSQL revision staging. This operator
path still performs work proportional to repository size. Suspended and taken-down accounts are
rejected; active/deactivated status is preserved.

A different key installs an envelope under the active encryption master key and
publishes a newer commit over the unchanged tree, retained revision-key metadata,
and a sync event in one transaction. Quota or publication failure rolls back all
changes, including a newly inserted vault row. Historical revisions retain their
original verification keys. Supplying the original key repairs missing or corrupt
custody without changing the commit or emitting a sync event; a readable same-key
retry preserves its envelope. Master-key rewrapping remains a separate operation.

This cannot reconstruct private material from a public key. The caller must
provide the authorized private key and an active encryption master key. Durable
replacement-key custody and the operator recovery workflow are described below.

### Repository-key custody during recovery

`Atoll.Identity.PLC.PendingSigningKeys.stage_recovery/6` stores a supplied
repository private key atomically with the verified signed recovery journal.
It checks the expected current local public key, validates the supplied key pair,
and requires the signed operation to authorize that public key. Recovery staging
allows missing or unreadable old custody and permits the original key for
same-key repair. Ordinary `stage/5` continues to require readable old custody
and a different replacement public key.

Recovery uses the existing authenticated pending-key envelope, binding the DID,
operation CID, expected old public key, curve and supplied public key. Exact
retries retain the envelope; the same pending-update and retained-key limits
apply. Master-key rewrapping includes this custody even when the active repository
vault is missing. The caller must still authorize recovery and supply fresh
directory evidence before staging.

After fresh verified directory acceptance, callers can restore the repository
key, complete the recovery journal and release pending custody in one transaction.
Failed publication retains the confirmed journal and encrypted key for retry;
release requires matching readable installed custody and completed journal state.
The `stage-key` command below accepts a recovery private-key file and uses this
custody through submission and local completion.

### Operator recovery with a supplied repository key

Use `stage-key` when the signed recovery authorizes a replacement repository key,
or when the original private key is available but its vault envelope is missing
or unreadable:

```sh
mix atoll.plc.recover stage-key did:plc:ACCOUNT signed-recovery.json /secure/repository-key.json EXPECTED_CURRENT_DID_KEY
mix atoll.plc.recover resume did:plc:ACCOUNT STAGED_OPERATION_CID
```

The private-key JSON file must contain exactly `curve` (`k256` or `p256`) and
`privateKey` (standard base64 for 32 private-key bytes), within 4 KiB. Restrict
file permissions to the operator. The expected public did:key refers to the
current local repository key, even if its private vault envelope is unreadable.
The signed recovery must authorize the supplied public key and preserve the
local handle/PDS service while retaining a readable local PLC authority.

Staging verifies the key pair, fresh recovery evidence, forward handle claim and
expected local public key before atomically storing the operation and encrypted
key. Output contains public metadata only. Resume needs the staged CID, not the
private file; keep your secure backup until recovery is verified. Active
encryption-master-key configuration is required for pending and installed custody.

After verified acceptance, local completion revokes credentials, emits the
identity event, restores custody and publishes a new unchanged-tree commit plus
a sync event when the repository key changes. It updates the identity observation,
completes the journal, removes pending private-key custody and records public key
identifiers in the recovery audit, all in one transaction. Same-key repair emits
only the identity event. Quota or verification failure rolls back local changes
and retains the encrypted key and confirmed journal for retry. Completed retries
do not revoke newly created sessions or duplicate events/audits.

This supports missing or unreadable repository custody; the retained PLC authority
must still be readable and authorized by the recovery operation. Authority restoration and combined recovery are described below. Handling
conflicting pending operations is supported for explicitly nullified history;
other conflicts remain unfinished. Recovery still requires an authorized signing key; private
keys cannot be reconstructed from public keys.

### Internal recovery of PLC authority custody

`PendingAuthorityKeys.stage_recovery/6` stages a supplied PLC authority private
key alongside a verified recovery fork. It checks the expected retained public
key from local metadata without requiring the old private envelope to decrypt.
The signed recovery must authorize the supplied key in its rotation-key list.
Same-key repair is supported; recovery may also replace the authority entirely.
Ordinary authority staging still requires readable old custody and a different
key in the same priority position.

Recovery authority envelopes use a distinct authenticated-encryption domain,
binding the DID, signed operation CID, expected old public key, curve and new
public key. Exact retries preserve custody, and master-key rewrapping includes
it. Caller authorization and fresh recovery evidence are still required.
`RotationKeys.public_key/1` reads preferred retained public metadata without
opening either the installed or signup private envelope.

After fresh verified directory acceptance, `RotationKeys.restore_pending!/2`
can install the supplied key under the active master key in the same transaction
as journal completion and pending-custody release. It checks confirmation,
account status and expected retained public metadata, while permitting an
unreadable old envelope. Ordinary `adopt_pending!/2` rejects recovery journals
and retains its old-key readability requirement. Failed transactions preserve
prior custody and the pending key. Neither path changes the repository signing
key or emits repository events itself.

This supports loss of the old authority's encryption master key when the
replacement private key and an authorized signed recovery are available. It
does not recover private material from public metadata or repair other vault
envelopes encrypted under a lost master key. The original signup envelope remains
retained, with the installed authority taking precedence. Operator integration and simultaneous repository/authority recovery are
described below. Conflicting pending-operation handling remains unfinished.

### Operator authority-only and combined key recovery

The recovery command also accepts an authority key alone, or both repository and
authority keys under the same signed fork:

```sh
mix atoll.plc.recover stage-authority did:plc:ACCOUNT signed-recovery.json /secure/authority.json EXPECTED_AUTHORITY_DID_KEY
mix atoll.plc.recover stage-keys did:plc:ACCOUNT signed-recovery.json /secure/repository.json EXPECTED_REPOSITORY_DID_KEY /secure/authority.json EXPECTED_AUTHORITY_DID_KEY
mix atoll.plc.recover resume did:plc:ACCOUNT STAGED_OPERATION_CID
```

Each private-key file uses the same strict 4 KiB JSON format as `stage-key`. Each
expected did:key is compared with the corresponding retained public metadata;
the signed recovery must authorize the supplied repository key and include the
supplied authority in its rotation-key list. Omitted keys must remain readable
and compatible with the recovered identity. The local PDS service and handle
checks, recovery priority/window verification, and reviewed-head protections
apply to every form. The external key signing the fork is not supplied to Atoll.

Both envelopes and the journal stage in one transaction. Resume needs only the
CID after staging. Following verified directory acceptance, authority installation,
repository restoration, credential revocation, identity observation/event, any
new repository commit/sync event, journal completion, pending-secret erasure and
public-metadata audit all commit atomically. Repository publication failure rolls
back authority installation as well, leaving both pending keys available for
retry. Authority-only repair does not change the repository commit.

Combined recovery can restore both active vaults under a new master key even if
the old master key is lost, provided authorized replacement private keys and a
valid signed recovery remain available. When authority metadata is missing, use
the explicit `absent` expectation below. Conflicting pending operations still
need an operator reconciliation workflow. The old signup envelope remains retained as
historical custody and may remain unreadable; recovery does not restore lost
master keys or make those old envelopes rewrappable. The explicit retirement
command below can remove superseded signup custody so future rewraps can proceed.

The migration permits both key purposes only for recovery journals. Ordinary
rotation retains the one-purpose constraint. Rolling back this migration refuses
existing combined-key journal rows rather than discarding their metadata.


### Retiring superseded signup key custody

After a completed PLC authority rotation or recovery, an operator can erase the
historical signup private-key envelope:

```sh
mix atoll.plc.retire_signup_key did:plc:ACCOUNT EXPECTED_GENESIS_CID EXPECTED_INSTALLED_DID_KEY
```

This is an explicit, irreversible local custody operation. Keep an offline backup
first if the original key is still useful for recovery. It does not remove that
key from directory history or the current rotation-key list, change the installed
key, erase database backups/WAL, or claim that the directory has not changed since
local reconciliation. It performs no network request. Signed genesis, its CID,
public key metadata, and signup confirmation/completion timestamps remain intact.

The command locks the account, requires active/deactivated status and completed
signup, checks both expected public identifiers, rejects pending PLC updates, and
verifies readable repository and separately installed authority custody. The
installed authority must reference a confirmed, locally completed update whose
rotation-key list authorizes it. Directly imported custody without that completed
journal is insufficient. An unreadable historical signup envelope can be retired;
an unreadable installed authority or repository key cannot.

Envelope erasure, retirement timestamp, and public-metadata audit commit together.
Retries recheck the prerequisites without rewriting the timestamp or duplicating
the audit. No repository commit or stream event is emitted. Master-key rewrapping
skips explicitly retired signup envelopes while continuing to check installed and
pending custody. Other unreadable envelopes still fail the entire rewrap page.
Rolling back the retirement migration refuses rows with erased envelopes, since
those private keys cannot be reconstructed.


### Recovery with absent authority metadata

For an account with neither a retained signup authority row nor an installed
PLC authority row, supply the authorized private key and explicitly expect
`absent` instead of an old authority did:key:

```sh
mix atoll.plc.recover stage-authority did:plc:ACCOUNT signed-recovery.json /secure/authority.json absent
mix atoll.plc.recover stage-keys did:plc:ACCOUNT signed-recovery.json /secure/repository.json EXPECTED_REPOSITORY_DID_KEY /secure/authority.json absent
mix atoll.plc.recover resume did:plc:ACCOUNT STAGED_OPERATION_CID
```

The internal APIs accept the atom `:absent` for the authority expectation only.
A missing repository private envelope still requires the repository's existing
public metadata and its expected did:key. Missing or corrupt authority *private*
custody with retained public metadata must use that public did:key, not `absent`.
This workflow cannot reconstruct any lost private key or recreate signed signup
history. The supplied authority must be authorized by the signed recovery, and
all recovery signature, priority, expiry, fresh-directory, handle, and local PDS
checks still apply.

For a recovery row with authority public metadata, a null expected authority key
records the explicit absence expectation. It is bound into the authenticated
pending-key envelope; changing it prevents decryption. Ordinary rotation still
requires existing authority metadata. Staging and resume check absence under the
account lock; any newly installed or restored metadata causes a stale-key error,
even if it names the intended replacement key. The pending journal and custody
remain available for operator reconciliation rather than overwriting that change.
Completion installs supplied custody, releases pending secrets, and audits the
previously absent state atomically with the other recovery changes. Completed
retries verify the now-installed key normally. Downgrading the schema refuses
existing absent-authority recovery rows rather than inventing old key metadata.


### Reconciling nullified pending PLC work

A pending operation may have been accepted by the directory and then nullified
by a higher-priority recovery before Atoll finished its local workflow. Close
that pending work using its exact CID and the expected current directory head:

```sh
mix atoll.plc.reconcile_nullified did:plc:ACCOUNT PENDING_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID
```

The command fetches fresh bounded audit history, verifies signatures and recovery
nullifications, and checks the latest directory endpoint against that history.
It requires the reviewed head and an explicit nullification entry matching the
stored signed operation. It rejects active operations, operations absent from the
log, stale head expectations, and locally completed work. It never POSTs to the
directory. See the [PLC recovery specification](https://web.plc.directory/spec/v0.1/did-plc).

Under account locks, closure atomically records a separate nullified terminal
state and observed directory head, erases this journal's pending private-key
envelopes, releases only handle reservations with its DID/CID, and appends a
public-metadata operator audit. Signed operations, public key metadata, review
scope, and any original confirmation timestamp remain retained. Completion is
not fabricated. The pending-operation slot becomes available for a new verified
workflow; stage and submit cannot reopen the closed journal. In-flight submission
confirmation and local completion also check the terminal state under lock.
Retries fetch fresh evidence and do not duplicate the audit or closure timestamp.

Installed private keys, local profile, repository, sessions, and account status
are unchanged, and no stream event is emitted. Closing dead work does not itself
reconcile the current directory identity or revoke compromised credentials. Run
the appropriate identity/recovery workflow afterward. Active and deactivated
accounts are supported. Remaining conflict handling includes operations not
explicitly nullified in verified history and recovery supersession before remote
acceptance. Do not delete or mark these operations completed to bypass the journal.
Schema downgrade refuses existing nullified rows rather than reopening them.


### Reconciling active pending PLC work

If an ordinary handle update or signed submission was accepted, but the directory
advanced again before local completion, reconcile against a reviewed current head:

```sh
mix atoll.plc.reconcile_active did:plc:ACCOUNT PENDING_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID
```

The command fetches fresh verified audit history and checks its latest head. The
pending CID must remain on the active chain and its signed operation must match
the local journal. Both that operation and the latest head must advertise the
local repository signing key, this PDS endpoint, and the intended primary handle.
Additional aliases or unrelated services on the latest head are allowed. Custom
handles require fresh forward resolution to the same DID. It makes no directory
POST and cannot reconcile an absent or nullified operation this way.

Under the event/account locks, Atoll rechecks key custody, profile, pending workflow,
and handle reservation. A changed handle requires the exact matching reservation,
an unchanged previous profile handle, and an available destination name. Completion
atomically updates the profile and identity observation, confirms/completes the
journal, releases its reservation, emits one identity event, and writes a private
operator audit containing the operation CID and observed directory head. Existing
confirmation timestamps are preserved. Completed retries verify fresh evidence
without repeating events or audits.

Active and deactivated accounts are supported; status, sessions, repository data,
and installed keys are preserved. Pending signup, recovery, and key-replacement
journals are rejected and require their dedicated workflows. This command does
not resolve key/recovery supersession or operations absent from directory history.
Local locks cannot prevent a later external directory update; a failed freshness or
compatibility check leaves the pending state for further review.

### Absent PLC operation closure

`mix atoll.plc.reconcile_absent DID PENDING_OPERATION_CID EXPECTED_DIRECTORY_HEAD_CID`
closes a pending journal entry that fresh verified directory history never
recorded — a submission the directory lost or refused, or a journal stranded
because the directory identity diverged through an unrelated fork or a
tombstone. Closure requires operator review of the current head and that the
operation can no longer land there: its signed predecessor must no longer be
the surviving head (a tombstoned identity always qualifies). An operation whose
predecessor is still the current head remains submittable and is refused; use
submission or active reconciliation instead.

Closure marks the journal with the closure head, erases only pending private
custody envelopes, and releases the operation's handle reservations, exactly
like nullification reconciliation; the signed operation history is retained and
no identity event is emitted. Operations recorded in active history, explicitly
nullified operations (use `mix atoll.plc.reconcile_nullified`), locally
completed work, and recovery journals with their own expected-head workflow are
all rejected. The operator audit entry records the observed head, the tombstone
flag, and the released reservations; repeated runs are idempotent.

