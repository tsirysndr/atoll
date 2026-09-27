# Accounts

Signup, invites, email, app passwords, deletion, preferences, and account recovery flows.

### Email delivery

All email features must use `Atoll.Email.deliver/3`, which submits messages to an
external Cloudflare Worker. Configure both settings before starting Atoll:

```sh
export ATOLL_EMAIL_WORKER_URL=https://your-worker.example.com/send
export ATOLL_EMAIL_WORKER_TOKEN='<shared bearer secret>'
```

Alternatively set `config :atoll, :email_worker, url: "https://...", token: "..."`
in configuration using your secret source. Environment overrides must supply both
variables and replace the configured pair together. Neither setting configured
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
full account access. OAuth access uses the separate permission and DPoP checks described below.


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
verification and caller-supplied PLC operations are not supported by this
fresh-signup path. Custom-domain signup uses the operator reservation flow below; existing-DID migration still requires its
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
resumable. Attempted registrations remain retained for reconciliation. The
operator cleanup command below can remove old reservations never submitted by
Atoll. Optional scheduled cleanup and registration retries are described below. No configuration in this change enables signup
on the running deployment or submits live registrations.


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
CLI issuance uses the same transactional audit boundary as the admin API, with
actor `operator` rather than `admin`. Its `com.atproto.server.createInviteCode`
entry retains the requested use count/owner and a SHA-256 code digest, never the
redeemable code. An audit failure rolls back issuance before the CLI prints the
code. Inspect entries with `mix atoll.moderation.history`.

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


### Custom-domain signup and DID reservation

Enable both `ATOLL_SIGNUP_ENABLED=true` and
`ATOLL_CUSTOM_DOMAIN_SIGNUP_ENABLED=true` to admit fresh PLC accounts with custom
handles. Custom-domain signup defaults to disabled. It uses a two-step flow so
the domain owner can publish a forward claim for the exact new DID before account
activation. The public `createAccount` endpoint does not allocate new custom-domain
reservations; use the operator command below or enable the browser reservation
flow.

Create a private JSON file (mode `0600`) with the same fields you will submit to
`createAccount`: `handle`, `password`, and optional `email`, `inviteCode`, and
`recoveryKey`. Then run:

```sh
mix atoll.accounts.reserve_custom_signup /secure/signup.json
```

The command reads at most 4 KiB and rejects duplicate JSON keys. It atomically
reserves the profile, credentials, deactivated repository, encrypted keys, signed
PLC genesis, invite redemption when applicable, and a public-metadata operator
audit. It prints only the DID, handle, DNS TXT name/value and HTTPS setup URL.
It does not publish to PLC, send email, activate the account or issue sessions.
Exact password-authenticated retries reuse the same DID and signed genesis
without consuming another invite use or duplicating the audit.

Publish the printed `did=...` TXT value at `_atproto.HANDLE`, or serve the printed
DID as plain text at `https://HANDLE/.well-known/atproto-did`. Then submit the same
JSON fields to `com.atproto.server.createAccount`, without a `did` field (that
field selects the separate existing-DID migration flow). Atoll forces fresh handle
resolution before PLC publication and again before local activation. DNS
precedence, conflicting-claim rejection, and public-address HTTPS restrictions
are inherited from the normal handle resolver. Hosted handles keep their existing
single-request signup flow.

Missing or mismatched claims leave the reservation pending. If ownership changes
during PLC publication, directory confirmation may already exist, but the account
stays deactivated with no session until a valid retry. Normalized profile details,
password proof, invite and recovery key must still match; publication/session
failures retain the exact journal for retry. No configuration is enabled on the
running deployment by adding this feature. Phone verification and signup recovery
requiring changed local identity remain unfinished. Bounded
operator and scheduled cleanup of unsubmitted reservations are described below.


#### Self-service browser reservation

Also set `ATOLL_CUSTOM_DOMAIN_SIGNUP_SELF_SERVICE_ENABLED=true` (or
`config :atoll, :custom_domain_signup_self_service_enabled, true`) to show
**Reserve a custom-domain DID** on `/account/signup` during a live OAuth
`prompt=create` flow. This separate setting defaults to false; both ordinary
signup and custom-domain signup must also be enabled. An unset environment value
preserves application configuration, while invalid values reject startup.

Enter the custom handle, password and optional email/invitation, then choose the
reservation button. The page displays the reserved DID and DNS TXT/HTTPS setup
instructions. After publishing the claim, submit **Create account** with the
same details. If DNS setup outlives the OAuth request, start a new signup request
from the client application and reuse those details to retrieve the same DID.
The page does not retain passwords, emails or invitations in form values or the
browser session. Reservation does not issue a session, mark the OAuth creation
complete, publish to PLC or grant application permissions. Existing browser
sessions do not satisfy the new account's creation requirement. Opt-in signup
retry workers can finish a reservation later once the forward claim verifies;
if that happens, restart ordinary sign-in with the created account.

The action shares the browser signup's CSRF/view checks, strict form parsing,
login-hint constraint and ten-POST-per-IP/five-minute budget. Existing invitation,
password, profile uniqueness, encrypted custody and exact-retry checks apply.
A first reservation writes a credential-free audit entry with actor `signup`;
the operator command retains actor `operator`. Audit failure rolls back all
reservation changes. Repeated exact reservations do not duplicate audit rows or
redeem another invite use.

`config :atoll, :custom_signup_reservation_limit, 1000` caps admission of new
self-service reservations. It counts all unfinished PLC signup journals, including
hosted-handle signup attempts, under the same transaction lock as insertion.
Values must be integers from 1 through 10000; a full queue or invalid setting
returns HTTP 503 without inserting new state. Password-authenticated retries
remain possible at capacity. The limit does not restrict operator reservations
or ordinary hosted signup. Use the existing unsubmitted-reservation cleanup
workflow to reclaim abandoned reservations; never delete a confirmed journal
merely to make space.


### Cleaning up unsubmitted signup reservations

Preview old signup reservations before applying a bounded cleanup page:

```sh
mix atoll.accounts.cleanup_signups --older-than-days 7 --limit 100
mix atoll.accounts.cleanup_signups --older-than-days 7 --limit 100 --apply
```

The command defaults to dry-run, seven days since reservation creation, and a
100-account limit. Allowed bounds are 1–3650 days and 1–100 accounts. Output contains
the cutoff, selected DIDs, selected/deleted counts, dry-run mode, and `more`.
Repeat applied pages while `more` is true. Preview always returns the first page
without advancing or changing state. Age is based on creation, not last retry;
review the selected DIDs before deleting reservations still awaiting DNS setup.

Only deactivated reservations with no PLC submission marker, confirmation, or
signup completion are eligible. Before any genesis POST, Atoll now commits a
`submission_started_at` marker under the same event/account locks used by cleanup.
If cleanup wins first, submission stops because the reservation no longer exists.
If publication wins first, cleanup skips it—even after timeout, rejection, crash,
or missing readback. The first marker persists across retries. This records an
Atoll attempt, not proof of directory acceptance or rejection.

The migration conservatively marks **all existing registrations** as protected,
using confirmation time when available and migration time otherwise. Those
legacy markers do not establish an actual historical submission time. Complete
the upgrade on every writer before applying cleanup; older application versions
do not write the marker. This workflow cannot detect a signed genesis published
outside Atoll. Attempted and legacy registrations can be resumed with the exact
operator command below; they are never automatically inferred safe to delete
from a 404 response. Divergent directory identities require separate reconciliation.

Each applied page commits atomically. Cleanup records its age/eligibility decision
and uses the audited account-deletion path: local profile, credentials, vaults,
registration and other account-owned rows are removed, old stream events are
withdrawn, a deleted-account event is emitted, and owned blob bytes are queued for
physical cleanup. Audit history remains. Invite uses are not refunded. Database
lock/statement timeouts roll back the page for retry. No PLC request or email is
sent. Optional scheduling is described below. Reconciliation of attempted or
ambiguous registrations remains unfinished.


### Scheduled signup cleanup

After reviewing the dry-run output and upgrading every writer to the submission
marker implementation, enable automatic cleanup explicitly:

```sh
export ATOLL_SIGNUP_CLEANUP_ENABLED=true
export ATOLL_SIGNUP_CLEANUP_AGE_DAYS=7
export ATOLL_SIGNUP_CLEANUP_BATCH_SIZE=100
export ATOLL_SIGNUP_CLEANUP_INTERVAL_SECONDS=3600
```

Cleanup is disabled by default, independently of signup admission. Configuration
is validated at startup: age is 1–3650 days, batch size 1–100, and interval
60–86400 seconds. Defaults are seven days, 100 reservations and one hour. These
settings schedule actual deletion, not dry-run; all eligibility, legacy protection,
audit, invite-use, and publication-locking rules of the operator command apply.

The supervised worker first runs after 60 seconds, then processes one page per
configured interval after the preceding run finishes. It does not immediately
drain a backlog when `more` is true. There is at most one task per worker; duplicate
manual triggers do not overlap a running task. A 15-second task deadline cancels
stalled work, and later ticks retry after failures. Shutdown terminates any running
task. Database transactions provide atomic deletion; losing the task's response
can leave a committed page, so telemetry is operational feedback rather than an
exactly-once deletion ledger. Durable audit history records committed cleanup.

Each instance has its own worker and budget. The shared database event lock
serializes pages with pre-publication marking across instances, preventing two
workers from deleting the same reservation. Scheduled cleanup and its associated
account-deletion audit entries use actor `system`; manual cleanup uses `operator`.
No network or email operation is initiated by the worker.

Telemetry event `[:atoll, :accounts, :signup_cleanup]` reports `runs`, and on
success `selected` and `deleted` counts. Metadata contains `result` (`ok`, `failed`,
or `timeout`) and `more`. DIDs, handles, credentials and cutoff strings are excluded.
Automatic startup is suppressed in tests; worker tests use supervised isolated
instances, explicit timer delivery and mocked failures. Exact pending signup
resume and automatic retries are described below. Compatible directory advancement
can be reconciled explicitly; changed local identity still requires recovery work.


### Operator resume of a pending signup

An operator can resume an admitted reservation after an ambiguous PLC response or
interrupted activation without obtaining the account owner's password:

```sh
mix atoll.accounts.resume_signup did:plc:ACCOUNT EXPECTED_GENESIS_CID
```

This trusted operator command snapshots the stored profile, credential digest,
invite redemption, recovery-key selection and signed genesis under account locks.
It requires the exact expected genesis CID, a deactivated pending account, and
matching local handle, repository public key and PDS endpoint. The current signup
admission switches may be disabled: this completes an existing reservation and
does not admit a new one. Missing credentials, changed public metadata, unavailable
private custody or non-deactivated pending accounts prevent completion.

Custom handles must freshly resolve to the reserved DID before publication and
again before activation. The command retries only the original signed genesis,
using the durable submission marker and directory readback. It never generates a
replacement DID or silently follows a divergent directory head. Network failures
retain the reservation for retry. Credential or profile changes during publication
invalidate the captured proof, leaving the confirmed account pending until a new
operator attempt captures and checks the updated state.

Activation, completion and an operator audit entry commit atomically. No password,
email, private key, access token or refresh token is printed; no session or email
is created, and session-signing configuration is not required for this operation.
The owner logs in through the normal session endpoint afterward. Completed retries
only report current local status, without a network request, repeated audit, or
reactivating an account subsequently deactivated or suspended. That read-only
result does not assert fresh directory compatibility. Automatic scheduling is
described below. A compatible successor of the stored genesis can be reconciled
with the explicit command below; changing local identity or keys remains separate
recovery work.


### Automatic signup retries

Enable retries of interrupted signup publication/activation explicitly:

```sh
export ATOLL_SIGNUP_RETRY_ENABLED=true
export ATOLL_SIGNUP_RETRY_INTERVAL_SECONDS=30
export ATOLL_SIGNUP_RETRY_DELAY_SECONDS=300
```

Disabled by default, independently of new-signup admission. Each instance starts
checking after 60 seconds and runs one registration at a time, with the configured
interval after each run. Interval bounds are 1–3600 seconds; delay bounds are
60–86400 seconds. The first automatic attempt waits at least the delay after the
recorded submission start. Subsequent attempts use a persisted next-attempt time.
Only incomplete, deactivated registrations explicitly eligible for retry are
selected. Untouched custom-domain reservations and unconfirmed legacy rows with
unknown publication history are excluded. A real genesis submission sets retry
eligibility before POST; migration only marks already-confirmed legacy rows
eligible. Operators can explicitly resume other legacy rows after review.

A PostgreSQL claim locks one due registration with `SKIP LOCKED`, installs a random
60-second lease token, and advances its next-attempt time before network work.
Candidates are ordered by their stored retry time or initial submission time,
then DID. Failing accounts are deferred so other reservations can proceed; task
crashes and restarts retain that delay. Separate instances coordinate through
these rows. No database transaction is held during DNS, HTTPS or PLC requests.

The task uses the exact operator-resume workflow, including custom-handle checks,
credential/profile rechecks, unchanged genesis, encrypted custody, and atomic
activation/audit. It creates no sessions and sends no email. Both preflight and
activation check the token against database time under account locks, so expired
or replaced workers cannot activate an account. A 45-second task deadline cancels
stalled runs. Remote publication cannot be atomically fenced: overlapping manual
retries or an expired task can submit the same immutable genesis more than once;
local completion remains guarded and does not generate a replacement identity.

Telemetry `[:atoll, :accounts, :signup_retry]` contains `runs`, plus `attempted`,
`completed`, and `failed` counts when the coordinator returns normally. Metadata
`result` is `ok`, `failed`, or `timeout`; no DID or credential is included. `ok`
means the retry coordinator finished, so inspect its `failed` count for account
failures. Completion audit uses actor `system`. Response loss can outlive a committed
activation; telemetry is not an exactly-once ledger. Automatic startup is disabled
in tests. Directory divergence remains an operator reconciliation case rather
than an automatic identity rewrite.


### Signup reconciliation after compatible directory advancement

If the directory advanced beyond a reservation's genesis before local signup
completed, an operator can activate it from verified current history:

```sh
mix atoll.accounts.reconcile_signup did:plc:ACCOUNT EXPECTED_GENESIS_CID EXPECTED_DIRECTORY_HEAD_CID
```

This command performs only directory GETs. It independently verifies the bounded
audit chain and fresh latest head, requires both expected CIDs, rejects tombstones,
and compares the signed genesis with the exact local reservation. The current
primary handle, repository verification key and PDS service must match the local
account, and the retained readable PLC authority must still be authorized. Extra
aliases or services do not prevent reconciliation when the primary identity still
matches. Custom-handle ownership is freshly verified. Incompatible handles,
services, signing keys or missing authority require separate identity recovery;
this command cannot rewrite them or synthesize replacement private keys.

Credential/profile changes during reads invalidate the captured reservation proof.
Pending PLC journals and handle reservations block activation until their own
workflows are reconciled. Under account locks, confirmation, completion, activation
and an operator audit containing genesis/current-head CIDs commit together. The
first confirmation timestamp is preserved if already present. No genesis is
resubmitted, no replacement DID is created, and no session or email is issued.
Automatic signup retries continue to use exact-genesis resume and do not invoke
this broader reconciliation automatically.

Completed retries still verify the expected directory head but only return local
status: they do not repeat activation/auditing, reactivate a subsequently disabled
account, or assert that its current local keys still match that head. As with other
identity workflows, a directory change after the final read cannot be made atomic
with the local database transaction; the audit records the head actually observed.

### Account preferences

`GET app.bsky.actor.getPreferences` and `POST app.bsky.actor.putPreferences`
serve the account's private client preferences from PostgreSQL, following the
[upstream reference behavior](https://github.com/bluesky-social/atproto/blob/7a857989751ae31518509d69ab7194a922064f3d/packages/pds/src/actor-store/preference).
Preferences never enter the signed repository, the firehose, or public reads.
Both endpoints accept password, app-password, and DPoP OAuth credentials, and
work for deactivated accounts under password sessions so migration tooling can
copy preferences before activation. Reads also accept full and takendown-scope
sessions of taken-down accounts, so owners can export preferences during a
takedown; writes stay blocked until the account is restored, and takendown
scopes never gain writes. Requests carry `no-store` responses, the shared
session rate budget, and a 256 KiB JSON body limit.

Bodies are validated against the pinned `app.bsky.actor.defs` preferences
union; the union is open, so unknown preference types are preserved as long as
each entry carries an `app.bsky`-namespaced `$type`. A put replaces exactly the
caller-visible `app.bsky` preferences and keeps entries outside that namespace.
The read-only declared-age preference is never stored: it is synthesized on
reads from a stored personal-details birth date. Personal details are limited
to full password sessions: app-password and OAuth callers cannot read or write
`personalDetailsPref` (writes return `InvalidRequest`; reads omit the entry
while still reporting the derived age flags), and existing personal details
survive their namespace replacements.

OAuth callers need `transition:generic` or granular `rpc:` grants for these
method NSIDs (matching the configured default AppView audience or a wildcard
audience). Writes use the shared pre-body proof admission and transactional
authorization recheck; reads run inside resource authorization locks. Requests
with an `Atproto-Proxy` header still proxy to the named service instead of the
local store. Run the migration creating the account-preferences table before
use; deleting an account removes its stored preferences.

### Signup queue status

`GET com.atproto.temp.checkSignupQueue` reports `{"activated": true}` for any
live password or app-password session, including deactivated accounts. Atoll
has no signup queue, so the [temporary upstream route](https://github.com/bluesky-social/atproto/blob/7a857989751ae31518509d69ab7194a922064f3d/packages/pds/src/api/com/atproto/temp/checkSignupQueue.ts)
is answered the same way the reference PDS answers without an entryway. As
upstream, OAuth credentials are refused. The route shares the session rate
budget and `no-store` responses.

### Signup recovery decision tree

A pending signup is recovered by matching the fresh verified directory state to
the tool built for it. With no recorded submission, `mix
atoll.accounts.resume_signup` retries the exact stored registration, and the
bounded cleanup command releases reservations that were never sent. When the
directory holds exactly the retained genesis, resume completes activation.
When the directory has advanced but the current identity still authorizes the
retained keys and matches the local handle and PDS, `mix
atoll.accounts.reconcile_signup` activates without posting anything.

A `did:plc` identity is derived from its genesis operation and controlled by
its rotation keys, so a directory head that no longer authorizes the retained
authority key — or a tombstone — cannot be recovered by any local action once
PLC's 72-hour fork window has passed. Recovery then means a changed identity:
register a fresh signup (new DID and keys) for the same handle after closing
the stranded state with the existing audited tools — `mix
atoll.plc.reconcile_nullified` or `mix atoll.plc.reconcile_absent` for pending
operations, and the signup cleanup path for the reservation. Nothing is deleted
implicitly and every closure keeps its journal history and audit entry.

Phone verification (`com.atproto.temp.requestPhoneVerification`) is served by
Bluesky's entryway, not by the reference PDS at the pinned revision, whose only
local `temp` route is the signup-queue check implemented above. Atoll matches
that surface; fresh signups gate on invite codes, email confirmation and rate
limits instead.


### Reserved handles

`ATOLL_RESERVED_HANDLES` holds comma-separated first labels that self-service
flows may not claim beneath the hosted handle domains; unset it to use the
built-in default list (`Atoll.Accounts.ReservedHandles.default/0`, including
`www`, `admin`, `mail`, `pds`, `cdn`, and similar operational names), or set
it empty to disable the check. Fresh signup, `com.atproto.identity.updateHandle`,
did:web handle changes, and authenticated PLC submission return
`HandleNotAvailable` for a reserved label. Operator endpoints stay
unrestricted so placeholders can be registered deliberately, and an account
already holding a reserved handle keeps claiming its own name. Custom-domain
handles are unaffected.
