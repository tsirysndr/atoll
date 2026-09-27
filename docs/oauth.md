# OAuth and browser authentication

The OAuth authorization/resource server, granular permissions, passkeys, and TOTP authenticators.

### OAuth DPoP verification foundation

`Atoll.OAuth.DPoP.verify/4` verifies a single DPoP header using ES256/P-256 and
returns its JWK thumbprint, proof ID, issue time, and nonce. It uses the existing
JOSE library for signature verification and RFC JWK thumbprints. This is an
internal cryptographic component used by the OAuth proof-admission layer.
Browser authorization, token exchange/refresh and local resource policies are
implemented by the adapters described below.

The caller supplies the externally visible method/URL, current time, and a recent
server-issued nonce. For protected-resource requests it must supply both the
validated access token and its bound `jkt`; the verifier checks both the SHA-256
`ath` and key binding. Token validity, account state, consent and scopes remain the
caller's responsibility. Successful proof verification must be followed by atomic
replay rejection before executing a request. The internal `Atoll.OAuth.Proofs`
guard below provides nonce validation and replay admission for PAR, token
requests and integrated resource policies.

Proofs are bounded to 8 KiB. The verifier rejects duplicate HTTP headers, duplicate
JSON members (including nested JWK members), excessive JSON nesting, noncanonical
base64url, private key material, unsupported algorithms and JOSE extensions, and
invalid signatures. It accepts both valid ECDSA signature forms; replay identity
must use the verified thumbprint/proof ID, not signature bytes. Proof IDs are
bounded to 256 bytes. Required server nonces are 16–256 printable ASCII bytes.
Proofs can be at most five minutes old or thirty seconds ahead of server time.

Request binding compares method and HTTP(S) target, excluding the actual request's
query as required by DPoP. The proof target itself must omit query and fragment;
userinfo is rejected. Scheme/host case, default ports, and an empty root path are
normalized; other path spellings are compared exactly. Callers must build the
expected URL from trusted public endpoint configuration rather than untrusted
forwarding headers.

The implementation follows the mandatory ES256 requirement in the
[ATProto OAuth profile](https://atproto.com/specs/oauth) and the proof checks in
[RFC 9449 §4.3](https://www.rfc-editor.org/rfc/rfc9449.html#section-4.3).

### OAuth server nonces and shared replay protection

`Atoll.OAuth.Nonce.issue/2` issues unpredictable, HMAC-authenticated nonces bound
to the public issuer and the `:authorization` or `:resource` server role. Configure
`ATOLL_OAUTH_NONCE_SECRET` with a base64-encoded random 32-byte secret; instances
serving the same issuer must share this secret and PostgreSQL database. The default
issuer is `AtollWeb.Endpoint.url()`. Nonces expire five minutes after issuance,
with five seconds of tolerance for clocks ahead at issuance. Changing the secret
invalidates outstanding nonces. Missing configuration fails closed when used;
it does not prevent startup. The PAR HTTP adapter returns 503 until configured.

`Atoll.OAuth.Proofs.verify/5` validates the nonce and signed proof, then atomically
admits its issuer/role/key-thumbprint/proof-ID digest into PostgreSQL. It uses the
database clock, checks expiry again after acquiring its shared admission lock,
and retains each marker until its nonce expires. Different signatures or a fresh
nonce cannot bypass a retained proof-ID marker. Resource proofs require both a
validated access token and its bound key thumbprint. The guard stores neither
proofs nor tokens, and does not establish account, client, consent, or scope
authorization.

Call this guard before the request's mutation transaction: admission commits
independently so a later request rollback cannot restore a consumed proof. Calls
inside an existing transaction are rejected. Storage is capped globally at
100,000 markers, with at most 1,000 expired markers reclaimed per successful
admission. Capacity exhaustion and database failures reject admission, with no
memory or Redis fallback. Queries use one-second lock and five-second statement
timeouts. The serialized admission lock and table count bound this initial
implementation's throughput; idle expired markers remain until new admissions
reclaim them.

Tests cover nonce expiry and issuer/role separation, token binding, concurrent
admission through independent database transactions, rollback behavior, replay
with a fresh nonce, and capacity exhaustion/reclamation. PAR/token nonce challenges
and local resource-route policies are implemented. `getSession` and the other
resource integrations are described below.

### OAuth client metadata foundation

`Atoll.OAuth.ClientMetadata.fetch/2` freshly retrieves a public HTTPS client-ID
document through the existing DNS-pinned resolver. It permits only public IP
destinations, preserves the original hostname for HTTP and TLS, refuses redirects
and compressed responses, and requires HTTP 200 with `application/json`. Response
bodies are capped at 64 KiB; duplicate JSON members and nesting beyond 16 levels
are rejected. DNS/connect timeouts are three seconds and the HTTP request timeout
is five seconds. There is no metadata cache or fallback to stale data. The
localhost virtual-client exception below synthesizes metadata without networking.

The returned document must exactly identify the requested client ID, declare
`atproto`, require DPoP, and declare the authorization-code flow. Refresh-token
grants are optional. Client IDs cannot contain credentials, fragments, or explicit
ports. URLs must use ASCII serialization (including punycode hostnames and
percent-encoded non-ASCII paths). Web callbacks require HTTPS; native callbacks
require the client's HTTPS origin or its reversed-domain custom scheme. Explicit
default HTTPS callback ports are rejected. `redirect_allowed?/2` compares the
entire callback exactly, including any query, except for virtual localhost
clients where only the loopback port is ignored. `scopes_allowed?/2` requires
`atproto` and checks that every requested scope is covered by the declaration.
Repository permissions may narrow collections/actions, blob permissions may
narrow accepted MIME patterns, and RPC permissions may narrow methods/audiences.
Coverage can combine declared scopes but never mix one RPC grant's method with
another grant's audience. Other scopes still require exact membership. This does
not grant permissions or replace consent and endpoint scope enforcement.

Local bounds are 32 distinct callbacks, 128 scope tokens in a 4 KiB scope string,
and 2 KiB URLs. The loader supports public `none` authentication and declarations
for confidential `private_key_jwt` clients using ES256. A confidential declaration
must identify exactly one inline or remote JWKS source; inline sets are limited
to 32 key objects. These declarations are **not verified client authentication**:
the `ClientKeys` loader below adds key validation and remote JWKS retrieval, while
the assertion guard below adds signature, replay, and supplied key-binding checks.
The code exchange below persists session bindings. Metadata branding is untrusted
and must not be displayed as verified application identity. Localhost virtual
clients and browser authorization are supported as described below.

The declaration rules follow the
[ATProto OAuth client profile](https://atproto.com/specs/oauth#clients).

### Confidential-client verification keys

`Atoll.OAuth.ClientKeys.fetch/2` freshly fetches and validates client metadata,
requires `private_key_jwt`, and reads its inline JWKS or fetches the declared
HTTPS JWKS URL. Remote key documents use the same DNS pinning, public-address
checks, timeouts, 64 KiB limit, exact HTTP 200/JSON requirement, and duplicate-member
rejection as client metadata. Neither metadata nor keys are cached by this loader;
an unavailable or invalid response fails without returning previously seen keys.

Key sets contain 0–32 ES256/P-256 public keys with distinct, case-sensitive `kid`
values of 1–256 printable ASCII bytes. Coordinates must be canonical base64url
encodings of exactly 32 bytes, and OpenSSL validates the full elliptic-curve point.
Private/symmetric key fields, duplicate IDs, other algorithms/curves, incompatible
`use`/`key_ops`, and key-level remote references are rejected. Optional `alg`,
`use`, and `key_ops` must be `ES256`, `sig`, and `["verify"]` when supplied. Only
the public curve and coordinates are passed to JOSE; unsupported keys invalidate
the set instead of being silently selected or ignored. An empty set represents
removal of all keys and cannot authenticate any assertion.

The result contains validated metadata and a map indexed by `kid`, with each
entry's public JOSE key, algorithm, and JWK thumbprint. Removal or replacement of
a key is visible on the next fetch, including replacement under an unchanged
`kid`. These are advertised verification keys, not proof of client authentication.
The assertion guard below verifies signatures, rejects replay, and can check an
original `kid`/`alg`/`jkt` binding. Code exchange persists that binding, and refresh
revokes its session when a freshly validated key set no longer contains that
key. The periodic worker below checks idle sessions as well.

### Confidential-client JWT assertions

`Atoll.OAuth.ClientAssertions.authenticate/5` accepts a client ID, assertion type,
compact JWT, trusted authorization-server issuer, and options. The type must be
`urn:ietf:params:oauth:client-assertion-type:jwt-bearer`. It freshly fetches client
metadata and verification keys before starting its replay-admission transaction.
The internal `verify/4` primitive performs only stateless checks against a
`ClientKeys.fetch/2` result and must not be used alone to admit requests.

Assertions are limited to 8 KiB, use ES256, and select an advertised key by `kid`.
Both `iss` and `sub` must exactly match the client ID; `aud` must be the issuer
string or a one-element array containing it. Assertions require integer `iat`
and `exp`, with a maximum five-minute lifetime, at most thirty seconds of future
issue-time skew, and no tolerance past expiry. An optional integer `nbf` must
already have passed. `jti` and `kid` are 1–256 printable ASCII bytes. Duplicate
JSON members, noncanonical base64url, invalid signatures, alternate algorithms,
embedded/remote header keys, and unsupported critical extensions are rejected.
Optional `typ` must be `JWT` or `jwt`.

For an existing session, pass `binding: %{kid: ..., alg: ..., jkt: ...}` from its
stored original client authentication. All three values must match the selected
freshly advertised key. Missing keys, replacement under the same ID, and changing
the selected ID cannot satisfy that binding. Omitting the option is for initial
authentication only; an explicitly supplied nil/incomplete binding fails. This
does not itself create, look up, or revoke a session.

Admission uses PostgreSQL time and a dedicated shared transaction lock. It stores
only a SHA-256 digest of issuer/client ID/assertion ID and the assertion's expiry.
Different signatures or signing keys cannot reuse a retained assertion ID.
Markers remain until expiry, with at most 1,000 expired markers reclaimed per
successful admission and a global cap of 100,000 assertion markers. Capacity and
database failures reject admission; SQL lock/statement timeouts are one/five
seconds. There is no memory or Redis fallback. The shared lock/table count limit
throughput, and idle expired markers remain until subsequent admissions reclaim
them. This store is separate from DPoP proof admission.

Run authentication before the request mutation transaction so a later request
rollback cannot restore a used assertion; nested calls fail. Concurrent submissions
through independent connections admit once. Tests also cover malformed JWTs,
key substitution, retained binding checks, expiry, capacity, and rollback behavior.
The result authenticates client software only: account authorization, DPoP,
PAR/PKCE, consent, OAuth sessions and token routes use the separate integrations
described below.
The assertion profile follows [RFC 7523](https://www.rfc-editor.org/rfc/rfc7523.html)
and the [ATProto confidential-client requirements](https://atproto.com/specs/oauth#confidential-client-authentication).

### PKCE and pushed authorization request storage

`Atoll.OAuth.PKCE` validates canonical S256 challenges and compares a verifier's
SHA-256 challenge in constant time. Verifiers must contain 43–128 unreserved
ASCII characters. The test suite includes the RFC 7636 example. Only S256 is
accepted; plaintext challenges are rejected.

`Atoll.OAuth.PAR.push/3` takes decoded parameters, the DPoP header list, and trusted
options. It validates the request, freshly fetches client metadata, authenticates
confidential clients through the assertion guard, and admits a DPoP proof for
`POST <issuer>/oauth/par`. Public clients must declare `none`; confidential
clients must supply their assertion and type. The issuer defaults to the public
endpoint URL, with trusted `:issuer`/`:secret` and transport options available
for integration/tests. No caller-supplied URL or forwarding header selects the
expected proof target.

Requests require `response_type=code`, state, an exactly registered callback,
declared scopes including `atproto`, and an S256 challenge. Optional `login_hint`
is preserved but is not account authentication. An optional `dpop_jkt` must match
the verified proof key. Scope admission accepts `atproto`, the three transitional
scopes and granular `repo`/`blob`/`rpc`/`account`/`identity` permissions; `transition:chat.bsky` requires
`transition:generic`. Other permission resource types and permission sets await
implementation. Unknown fields, client secrets,
verifiers, Request Objects, and supplied request URIs are rejected. Input is capped
at 16 KiB of decoded names/values; state and login hints are capped at 2 KiB.
The HTTP form adapter rejects duplicate fields before producing a map.

Successful admission atomically reserves the challenge for 24 hours and stores
validated parameters, issuer/client ID, DPoP thumbprint, and any confidential
client key binding. It returns a random 256-bit `request_uri` with `expires_in: 90` (600 for `prompt=create`).
Only the reference's SHA-256 digest is stored, not its bearer value. Assertion and
DPoP JWT bytes are excluded from request storage; parameters include private state
and login hints, are redacted from struct inspection, and use queries without
parameter logging. Confidential key bindings in the database have JSON string
keys (`kid`, `alg`, `jkt`).

`PAR.get/3` retrieves an unexpired request only for its original client and issuer.
This read does not consume the request, establish consent, or issue a grant. A
decision service below atomically consumes it during code issuance and preserves
its stored parameters and bindings. The browser flow is described below. Request expiry does not free its
challenge reservation, and another client of the same issuer cannot reuse that
challenge during the reservation period.

PostgreSQL time and a dedicated shared admission lock serialize reservations.
Capacity is 10,000 stored pushed requests and 100,000 challenge markers globally;
each successful admission reclaims at most 1,000 expired rows from each table.
Full storage and database failures reject admission, with one-second lock and
five-second statement timeouts. No memory/Redis fallback is used. The shared lock
and table counts constrain throughput, and idle expired rows await later admission
for cleanup. Failed storage commits reserve neither a request nor a challenge;
already admitted assertions/DPoP proofs remain consumed, so retries need fresh
proofs. Calls inside a caller transaction are rejected.

Tests cover both client types, key binding, client/issuer isolation, expiry,
challenge reuse across clients, concurrent reservations, storage capacity, and
bounded reclamation. The HTTP adapter below exposes PAR admission. Browser
authorization and consent remain unfinished; code exchange and its HTTP adapter
are described below. Protocol references:
[PKCE (RFC 7636)](https://www.rfc-editor.org/rfc/rfc7636.html) and
[PAR (RFC 9126)](https://datatracker.ietf.org/doc/html/rfc9126).

### OAuth server discovery

`GET /.well-known/oauth-protected-resource` identifies this PDS and its colocated
authorization server. `GET /.well-known/oauth-authorization-server` advertises the
implemented authorization, PAR, token and revocation endpoints, PKCE S256, ES256 DPoP and
client assertions, public/confidential clients, refresh grants, transitional
scopes and `prompt=create`. Explicit `response_mode=query` is accepted by PAR;
other response modes are rejected. The static scope list includes `repo:*` and
`blob:*/*`; parameterized RPC permissions are also supported for service-token
issuance. The scope list is not exhaustive. Identity and account scopes are also advertised. Parameterized `include:` permission sets are supported.

Both documents derive their URLs from Phoenix Endpoint's configured public URL,
never request or forwarding headers. Configure a canonical HTTPS origin without a
path prefix; non-default ports are allowed. A mismatched request hostname returns
404, and invalid origin configuration returns 503. HTTP localhost discovery is
available only with the existing development/test `localhost_dids_enabled` opt-in.
Behind a reverse proxy, preserve the public Host header and configure the Endpoint
URL with the external scheme and port.

Discovery requires no credentials or cookies. GET returns JSON; HEAD returns the
same headers without a body. Both use a five-minute public cache lifetime and
`Access-Control-Allow-Origin: *`. OPTIONS
supports browser preflights for GET/HEAD and Accept, Accept-Language, Content-Type
headers. Query strings and encoded path aliases are rejected; unsupported methods
return 405 before request-body parsing. Error responses are not cached.

Metadata describes capabilities even when account signup is disabled or secrets
are unconfigured. PAR/token/revocation still require the configured OAuth nonce secret, and
account login requires the session secrets. Legacy Bearer sessions remain
supported, so resource metadata does not claim every access token is DPoP-bound.
No unimplemented registration, introspection, userinfo or JWKS endpoint
is advertised. Discovery follows the
[ATProto server metadata profile](https://atproto.com/specs/oauth#server-metadata).
HTTP tests follow discovery through PAR, password login, consent, code exchange,
a DPoP resource read, and source-session logout/revocation. They also cover origin
configuration, hostname isolation, CORS, HEAD and early method validation.

### PAR HTTP adapter

`POST /oauth/par` accepts `application/x-www-form-urlencoded` with UTF-8 encoding
and returns HTTP 201 with `request_uri` and `expires_in` after successful admission.
Configure `ATOLL_OAUTH_NONCE_SECRET` as described above; without it this route
returns HTTP 503 `temporarily_unavailable`. Discovery, browser consent, granular
permissions and local resource policies are available. Full-profile interoperability
auditing remains pending, so full OAuth support remains unchecked.

The boundary runs before general body parsing, method rewriting, and Phoenix
controller parameter logging. Forms are flat, limited to 13 fields and 48 KiB of
encoded bytes, with a five-second body read timeout and the internal 16 KiB
decoded-parameter cap. Duplicate names after percent decoding, invalid percent
escapes/UTF-8, nested fields, query parameters, compressed bodies, and header-based
client authentication are rejected. Only the canonical `/oauth/par` path is
accepted. Request methods other than POST and CORS OPTIONS receive 405.

All configured responses carry a fresh `DPoP-Nonce`, `Cache-Control: no-store`,
and public-origin CORS headers without cookie credentials. A missing, expired, or
invalid server nonce in a supplied proof returns HTTP 400 `use_dpop_nonce` before
fetching metadata or consuming a confidential assertion. Missing/duplicate DPoP
headers, invalid signatures, and replay return `invalid_dpop_proof`. Retry nonce
challenges with a newly signed proof using the response nonce. The full admission
guard still verifies signature and replay; the preliminary nonce check alone
does not authenticate the request.

The existing configured request limiter applies 20 attempts per peer IP per five
minutes before reading the form, including malformed requests and preflights.
Trusted proxy settings govern the peer address. Exhaustion returns 429 with
`Retry-After`; storage failures return 503. Proof URLs use the configured public
endpoint, never incoming Host or forwarding headers. CORS preflights allow POST
with `content-type` and `dpop`, and expose `dpop-nonce`/`retry-after`. OAuth errors
use the `error` field without reflecting assertion data or internal error details.
Phoenix parameter filtering also covers assertions, verifiers, request references,
state, and login hints for subsequent OAuth routes.

### Account approval and pending authorization codes

`Atoll.OAuth.AuthorizationCodes.decide/5` takes a full account access token,
client ID, pushed-request URI, explicit `:deny` or `{:approve, granted_scope}`
decision, and trusted options. It requires a live full-password session for an
active account; app-password sessions, deactivated accounts, revoked sessions,
and pending signups cannot approve. The future browser adapter must establish
CSRF-protected, explicit user consent before invoking it. Login hints and client
assertions never stand in for account authorization.

Approval may narrow the originally requested scope but cannot add scopes or
omit `atproto`; transitional chat scope still requires generic scope. Client
metadata and confidential keys are refreshed before committing approval. The
original callback and granted scopes must still be declared, public clients must
remain public, and confidential clients must retain the same `kid`/`alg`/`jkt`.
Denial requires account authorization but no client network lookup and returns
`access_denied` for the original callback/state/issuer.

Account and session locks are acquired before the shared PAR lock. After network
retrieval and again after waiting for the PAR lock, authorization is rechecked;
the request must still be unexpired and match the reviewed snapshot. Approval
atomically deletes the request and inserts a random 256-bit code's SHA-256 digest.
Denial deletes it without issuing a code. Concurrent decisions can consume it
only once. Errors, including code-capacity exhaustion, leave the request available
while its original lifetime permits. Its 24-hour PKCE reservation is retained.

Pending codes expire after two minutes and retain the account DID, issuer,
client ID, exact redirect, granted scope, PKCE challenge, DPoP key, any confidential
client key binding, and whether the refreshed client declaration allows refresh
tokens. Plaintext codes are returned only to the caller; they are not stored.
The response also returns the original callback, state, and issuer for the
browser redirect adapter. Foreign keys remove pending codes when the account or
authorizing password session is deleted, including session revocation/recovery.

Code storage is capped at 10,000 rows globally under the PAR lock, reclaiming at
most 1,000 expired rows per successful approval. SQL lock/statement timeouts are
one/five seconds; database errors fail closed. Nested caller transactions are
rejected so client metadata retrieval never occurs inside the commit transaction.
Tests cover scope narrowing, account/session restrictions, changed client policy
and keys, revocation during metadata retrieval, expiry, capacity rollback, and
concurrent decisions through independent database connections.

This service does not render login/consent. The browser adapter renders those
screens, and the internal exchange below redeems the approved codes.

### Authorization-code exchange and opaque sessions

`Atoll.OAuth.CodeExchange.exchange/3` accepts decoded token parameters, DPoP
headers, and trusted server options. It checks the exact client, issuer, redirect,
S256 verifier, original DPoP key, and fresh client metadata before issuing tokens.
Confidential clients must prove their original client key with a fresh assertion.
The account and authorizing full-access password session are checked again under
database locks after network verification. Nested caller transactions are rejected.

Issuance atomically creates an `oauth_sessions` row and an `oauth_access_tokens`
row, then records the code's redemption. Access and optional refresh tokens contain
32 random bytes with `atoll_access_` and `atoll_refresh_` prefixes; only SHA-256
digests are stored. Responses include `token_type: DPoP`, `expires_in`, the approved
`scope`, and the account DID as `sub`. Raw tokens are returned only to the caller.

Access tokens last up to five minutes. Sessions with refresh tokens last up to
14 days for public clients and 180 days for confidential clients; access-only
sessions last five minutes. All lifetimes are also capped by the authorizing
password session's expiry. Deleting that source session (including logout or
recovery paths that delete it) cascades to derived OAuth sessions and tokens.
This coupling is Atoll's current policy, not an independent browser-login session.

A subsequent exchange with valid client, PKCE, and DPoP bindings returns
`invalid_grant` and commits deletion of the original OAuth session and its tokens.
Incorrect bindings cannot revoke a session. Redemption markers survive the code's
original expiry until the issued session expires, including during approval
cleanup. Concurrent independent exchanges issue once, then revoke on verified
reuse. These checks implement the [ATProto code-reuse rule](https://atproto.com/specs/oauth#proof-key-for-code-exchange-pkce).

The shared PAR lock serializes issuance and replay revocation. Storage permits
10,000 OAuth sessions globally and 100 live sessions per account, reclaiming at
most 1,000 expired sessions per issuance. SQL lock and statement timeouts are one
and five seconds. Database failures reject exchange; already consumed assertions
and DPoP proofs require fresh proofs on retry. Retained redemption markers count
against the separate 10,000-code cap.

Tests cover digest-only storage, binding failures, source-session revocation,
expiry, client metadata/key changes, access-only clients, capacity rollback,
marker retention, and concurrent redemption. The HTTP adapter below exposes this
service. Refresh rotation and DPoP `getSession` are described below. Browser
consent, discovery and local resource scope policies are implemented. The periodic
key checker is described below; full-profile interoperability auditing remains pending.


### Token HTTP adapter

`POST /oauth/token` accepts UTF-8 `application/x-www-form-urlencoded` requests
with `grant_type=authorization_code`, `client_id`, `code`, `redirect_uri`, and
`code_verifier`. Confidential clients additionally send `client_assertion_type`
and `client_assertion`. Supply a fresh DPoP proof targeting the configured
endpoint URL, using an authorization-server nonce; HTTP 400 `use_dpop_nonce`
provides a fresh `DPoP-Nonce` for retry before client metadata retrieval or
assertion consumption. Success returns HTTP 200 with the token response above.

PAR, token and revocation routes share `AtollWeb.OAuthRequestPlug`, ahead of general body
parsing, method overrides, and controller logging. The token route has a separate
20-request/five-minute peer budget, including malformed requests and preflight.
It inherits the 48 KiB encoded body limit, five-second body-read timeout, strict
flat/duplicate-free form decoding, canonical route checks, and trusted issuer
configuration. Code exchange further limits decoded fields to seven and their
combined size to 16 KiB. Query parameters, compressed bodies, unsupported media
types, unknown fields, and method overrides are rejected.

Configured responses include a fresh nonce, `Cache-Control: no-store`, and
`Pragma: no-cache`. CORS allows any origin without credentials, exposes the nonce
and retry headers, and permits only POST with `content-type` and `dpop`.
Unsupported methods return 405; unsupported grant types return HTTP 400
`unsupported_grant_type`. Invalid code bindings and verified reuse return
`invalid_grant`; malformed/replayed proofs return `invalid_dpop_proof`.
Authorization-header client credentials are unsupported and return
`invalid_client`, with HTTP 401 and a matching challenge for a valid scheme.
Client assertions belong in the form body.

Rate exhaustion returns 429; unavailable configuration or storage returns 503.
HTTP tests cover issuance, nonce retry, code-reuse revocation, proof replay,
malformed forms, CORS, peer limits, and configured-host binding. Response and
error shapes follow [RFC 6749 sections 5.1–5.2](https://www.rfc-editor.org/rfc/rfc6749.html#section-5.1).
Discovery and the public-client SDK flow are covered above; complete OAuth profile
interoperability auditing remains pending. The refresh grant is described below.


### Refresh rotation and token-family revocation

`POST /oauth/token` also accepts `grant_type=refresh_token`, `client_id`, and
`refresh_token`, plus an optional `scope` and the confidential-client assertion
fields. `Atoll.OAuth.Refresh.exchange/3` implements this grant. The route uses the
same nonce challenges, parsing, CORS, and peer budget as code exchange. Refresh
requires a new DPoP proof from the session's original key and freshly retrieved
client metadata; confidential clients must authenticate using the original
`kid`/`alg`/`jkt`. Proof and assertion replay admission commits before rotation.

Rotation locks and rechecks the active account, source password session, and
OAuth session. It atomically replaces the refresh digest, issues a five-minute
access token, and retains the consumed digest in `oauth_refresh_uses` until the
session expires. It never extends the original session lifetime. Source-session
expiry also caps new access tokens. Deleting the OAuth or source session removes
its access tokens and consumed-refresh markers through foreign keys.

Reusing any consumed refresh token with valid bindings revokes the session and
all its tokens, returning `invalid_grant` after committing the deletion. There
is no retry grace period: clients must serialize refresh calls, and losing a
successful response can require login again. Concurrent independent requests
produce one rotation followed by revocation. Wrong client IDs, wrong DPoP keys,
and invalid assertions cannot revoke an otherwise valid session.

A narrowed `scope` must be a subset of the original grant, retain `atproto`, and
respect the transitional chat dependency. It applies only to the new access
token, whose scope is stored explicitly; the replacement refresh token retains
the original grant. Omitting scope uses the original grant. The migration
backfills existing access-token scopes from their sessions before enforcing a
non-null column. Resource authorization must enforce the access token's scope;
`getSession`, repository record writes, and blob uploads now do so; other
resource integrations remain pending.

On refresh, a valid current confidential key set with the bound key removed or
replaced causes permanent session revocation, including an empty inline or
remote JWKS. Metadata/network validation failures reject refresh without treating
a failed lookup as evidence of removal. Refresh checks the requesting session;
the periodic checker below also checks idle sessions.

The existing shared PAR lock serializes rotation with code exchange and reuse
revocation. There is a global cap of 100,000 consumed refresh markers and a cap
of 100 live access tokens per session. Rotation reclaims at most 1,000 globally
expired markers and the current session's expired access tokens before admission.
Capacity failures roll back token replacement and cleanup; the HTTP response is
503 `temporarily_unavailable`. Existing one-second lock and five-second statement
timeouts apply. PostgreSQL stores the authoritative state with no memory or Redis
fallback. Idle expired state is reclaimed by subsequent admissions, not a timer.

Tests exercise real code issuance followed by rotation, per-access scope storage,
replay revocation, independent concurrent connections, source-session deletion
and expiry, metadata-time revocation, key replacement/removal, transient lookup
failure, storage capacity, bounded cleanup, and the HTTP refresh response.
The behavior follows the [ATProto token/session profile](https://atproto.com/specs/oauth#tokens-and-session-lifetime)
and [OAuth refresh semantics](https://www.rfc-editor.org/rfc/rfc6749.html#section-6).


### DPoP resource reads and session identity

`GET /xrpc/com.atproto.server.getSession` accepts `Authorization: DPoP <access_token>`
and a DPoP proof containing `ath` for that exact token, `htm: GET`, and `htu` for
the configured origin plus request path. It requires a resource-server nonce,
which is distinct from the authorization-server nonce used at `/oauth/token`.
An old or wrong-role nonce produces HTTP 401 with a fresh `DPoP-Nonce` and
`WWW-Authenticate: DPoP error="use_dpop_nonce", algs="ES256"`. Retry with a new
proof containing the supplied nonce.

`Atoll.OAuth.Resource.read/5` validates the opaque access-token digest, issuer,
proof/key binding, token hash, and shared replay state. Proof admission commits
before the read transaction. It then takes shared row locks on the account,
source password session, OAuth session, and access token, checks their current
expiry/status and scope, and invokes a trusted read callback while holding those
locks. The database clock is read after lock acquisition. A rollback in the
callback cannot restore an admitted proof. Callers may require additional scopes;
`atproto` and membership in the session's original grant are always required.
This callback is for database reads only, not network requests or writes.

The session response contains DID, handle, and active status. `transition:email`
or `account:email` (read or manage) in the **access token** adds email and confirmation status; a broader OAuth
session cannot restore email access to a narrowed token. OAuth responses omit
`emailAuthFactor` and never contain password-session JWTs. Inactive accounts,
expired/revoked tokens or source sessions, and unknown issuers cannot read through
this guard. Email management and repository import require explicit account
permissions as described below; other routes retain their authentication requirements.

The resource header plug runs before XRPC rate/method/query guards, so recognized
DPoP attempts receive fresh resource nonces even on early errors. CORS permits
the `dpop` request header and exposes `dpop-nonce` and `www-authenticate`, with
no credentials. Configuration/storage failures return 503, proof/token failures
return 401, and insufficient scopes return 403. Opaque OAuth tokens presented as
Bearer credentials are rejected. Legacy password-JWT `getSession` continues to
use its existing authentication and response behavior.

HTTP tests cover token issuance through session reads, email scope narrowing,
nonce roles, method/target/key/hash checks, proof replay, expiry/revocation,
account status, Bearer downgrade rejection, account-management denial, CORS,
rate-limit errors, configured-origin binding, and rollback persistence. An
independent-connection test verifies all four row locks remain held through the
read and that later reads fail after session deletion. Resource
challenges follow [RFC 9449 sections 7 and 9](https://www.rfc-editor.org/rfc/rfc9449.html#section-7).
Repository writes, blob uploads, service authorization, exports and account
inventory are integrated as described below. Other resource routes and
other fine-grained permissions still need endpoint-specific OAuth authorization.


### Periodic confidential-client key checks

`Atoll.OAuth.KeyCheckWorker` starts automatically outside the test environment.
It waits one minute after startup, then visits live confidential OAuth sessions
in `(client_id, session_id)` order. Configure it with:

```sh
export ATOLL_OAUTH_KEY_CHECKS_ENABLED=true
export ATOLL_OAUTH_KEY_CHECKS_INTERVAL_SECONDS=300
```

The interval accepts 30–3,600 seconds and is the delay **after a complete sweep**,
not a deadline for every session. One supervised task processes at most 100
sessions for one client, with one second between batches. Each task has a
20-second deadline; a slow or unavailable client cannot block all later clients.
The cursor is kept in memory and resets after each sweep or worker restart.
Session insertions before the current cursor are checked on the next sweep.
Set `ATOLL_OAUTH_KEY_CHECKS_ENABLED=false` to disable scheduling; refresh-time key
checks still run. Tests disable the application worker and start isolated workers.

`Atoll.OAuth.KeyChecks.run(cursor, options)` captures a bounded session snapshot,
fetches fresh validated metadata and inline/remote JWKS, and revokes sessions
whose original `kid`/`alg`/`jkt` is absent or replaced. An empty valid key set
revokes all snapshotted sessions for that client. Invalid documents and network
failures preserve the sessions and advance the cursor; they are retried on the
next sweep. No client credentials or account tokens are sent to metadata URLs.

Before deletion, the checker locks affected accounts and source password sessions,
then takes the shared OAuth mutation advisory lock and locks current OAuth rows.
Only unchanged snapshotted bindings are revoked. New grants or changed bindings
created during the fetch are not deleted based on the older observation; refresh
token rotation alone does not hide a removed key. Deletion cascades to access
tokens and refresh-reuse markers. Database failures roll back the batch, with
one-second lock and five-second statement timeouts. Metadata retrieval occurs
outside the transaction; nested caller transactions are rejected.

The worker advances past a selected batch even after a task timeout or crash,
and retries it on the next sweep. Failure before batch selection retries from
the same cursor after the interval. Repeated run requests do not overlap tasks;
shutdown cancels the active task. Telemetry `[:atoll, :oauth, :key_checks]` reports
`runs`, available `checked`/`revoked`/`failed` counts, and an outcome, without client
IDs, account identifiers, or credentials. Timeout outcomes cannot assert how many
rows committed before task termination.

Multiple application instances may run redundant fetches; database locks make
revocation safe, but there is no distributed scheduling lease. For one sweeper
per deployment, disable it on other instances. Sweep duration grows with the
number and latency of clients; this is not a five-minute revocation SLA. Changes
at a client's metadata server cannot be atomic with Atoll's database: decisions
use the fetched snapshot, and subsequent sweeps observe later changes.

Tests cover retained/removed/replaced keys, cascades, fetch failures, pagination,
public/expired sessions, metadata-time binding changes and deletion, refresh
rotation during fetch, one-task scheduling, timeouts, shutdown, and cursor reset.
This supplies the periodic retrieval required by the [ATProto confidential-client profile](https://atproto.com/specs/oauth#confidential-client-authentication).


### Localhost OAuth clients

Atoll accepts the virtual client IDs `http://localhost` and `http://localhost/`,
optionally with a query. `Atoll.OAuth.LocalhostClient` generates a public native
client declaration with `none` client authentication, mandatory DPoP, authorization
code and refresh grants, and default scope `atproto`. No DNS or HTTP request is
made to fetch this metadata, including on approval, token exchange, or refresh.
It is supported in production as well as development and is independent of the
`did:web:localhost` resolver setting.

The client ID must have the literal authority `localhost`, no explicit port
(including `:80`), no credentials or fragment, and an absent or root path. Optional
query parameters are one `scope` and up to 32 distinct `redirect_uri` values.
For example:

```text
http://localhost?redirect_uri=http%3A%2F%2F127.0.0.1%2Fcallback&scope=atproto+transition%3Ageneric
```

That declaration permits a PAR callback such as
`http://127.0.0.1:3000/callback`. Without a declared callback, the defaults are
`http://127.0.0.1/` and `http://[::1]/`. Matching ignores only the port; host, path,
and query must match. Empty URL paths match `/`. Callback hosts must be literal
`127.0.0.1` or `[::1]`, not `localhost`, aliases, other loopback representations,
or public/private network addresses. Callback ports must be 1–65,535. Credentials,
fragments, backslashes, malformed percent encodings, and dot path segments are
rejected. Unknown query fields, duplicate scope fields (including encoded names),
invalid scopes, invalid UTF-8, and URLs over 2 KiB are rejected as well.

The full original client ID remains the identifier: changing its query or adding
a slash does not preserve an existing grant's client binding. After PAR accepts
a callback, code exchange must present that exact callback including its port;
registration-time port flexibility cannot redirect an already issued code.
Ordinary HTTPS client metadata retains exact callback matching, and client
metadata extensions cannot opt it into localhost rules. Localhost clients cannot
authenticate with confidential-client assertions.

Tests cover safe defaults, repeated callbacks, scope parsing, ambiguous IDs and
queries, loopback restrictions, and a flow through HTTP PAR, internal account
approval, HTTP code exchange, refresh, and DPoP `getSession` with all metadata
network access prohibited. Browser login/consent is described below. The behavior
implements the [ATProto localhost client profile](https://atproto.com/specs/oauth#localhost-client-development).


### DPoP repository record writes

`com.atproto.repo.createRecord`, `putRecord`, `deleteRecord`, and `applyWrites`
accept DPoP access tokens with `atproto` and either `transition:generic` or
applicable granular repository permissions. A token narrowed to
`atproto` or email access cannot borrow the broader session grant. These routes
require the canonical XRPC path and a new POST proof bound to the configured
origin, resource nonce, access-token hash, and original DPoP key. Legacy password
and app-password JWT writes retain their existing behavior.

After the existing peer rate limit, `RecordWritePlug` admits the proof and checks
current authorization **before** parsing the bounded JSON body. It creates a
signed internal `WriteCredential` containing the access-token digest, a fingerprint
of the session binding, the operation, request-process identity, and a 30-second
expiry. The credential is never sent to clients and is redacted when inspected.
Its HMAC key is derived with a separate purpose from `ATOLL_OAUTH_NONCE_SECRET`;
changing that secret invalidates outstanding credentials. It cannot be used in
another process or for another operation, and HTTP token parsers do not accept it.

The write service uses the same ownership checks, handle resolution, schema
preparation, record validation, and swap constraints for both authentication
schemes. After network schema lookup, it takes the existing event-sequencing lock
and repository write lock, then rechecks the credential and current account,
source session, OAuth session, access expiry, and access-token scope under row
locks. These locks remain held through record/blob-reference changes, signed
commit creation, and event publication. Revocation or scope changes during schema
lookup therefore prevent mutation. All operations in `applyWrites` retain their
existing transaction atomicity.

Proof admission stays committed when parsing, validation, swaps, or the write
transaction fail. Retries need fresh proofs. Work that outlives the internal
credential also fails closed and must be retried; the credential is not a cache
of permission that can survive session revocation. Authorization failures use
DPoP challenges with 401/403, while existing record and validation errors retain
their XRPC responses. Fresh resource nonces and CORS headers remain available.

Tests cover all four methods, foreign-repository denial, schema and swap failures,
batch rollback, proof replay after failures, body limits, session revocation and
scope narrowing during schema lookup, and rejection of altered, expired,
wrong-operation, or foreign-process internal credentials. Granular repository
permissions are described next; other resource integrations remain tracked above.

### Granular repository permissions

Clients can request `repo:com.example.post` for create/update/delete access to one
collection, or restrict actions with
`repo:com.example.post?action=create&action=delete`. `repo:*` grants all collections;
`repo:*?action=delete` grants deletion only. Repeated `collection` query parameters
support several collections in one scope, for example
`repo?collection=com.example.post&collection=com.example.profile&action=create`.
Partial collection wildcards are rejected. Positional values and query parameters
support percent encoding; a positional collection cannot also appear in the query.
Unknown parameters, malformed encoding, invalid NSIDs/actions and duplicate action
values are rejected. Each scope is bounded by the existing 4 KiB/128-scope budget;
a single permission has at most 128 query parameters.

Client metadata declarations, consent grants and refresh requests use semantic
coverage for repository permissions. A broad collection/action grant can cover a
narrower request, and grants can combine their action coverage. Narrow collections
cannot cover a wildcard and omitted actions mean all three operations. This does
not allow a repository scope to become transitional generic access. Other scope
types retain exact membership checks.

The consent page names the collections and operations and lets the user uncheck
individual requested permissions. Checked fields refer to stored request scopes;
clients cannot submit new scope text in the form. Consent accepts up to 131 flat
fields within its existing 8 KiB body limit, accommodating all bounded scope
choices and CSRF/context fields. Other OAuth forms retain their 13-field limit.

Record requests must have a relevant permission before body parsing. After parsing,
each collection/action is checked before network schema lookup and again under
repository and authorization locks before mutation. `createRecord` requires
create, `deleteRecord` requires delete, and `putRecord` requires **both create and
update** even if a record already exists. Each `applyWrites` operation requires its
own action; one denied operation rejects the entire batch. Repository permissions
do not authorize blob uploads, email access or service-token issuance.

HTTP tests cover issuance through PAR/code exchange, browser selection of more than
thirteen permissions, refresh narrowing, collection/action denial, atomic batch
rejection and scope changes during schema lookup. Parsing and coverage tests include
wildcards, multiple collections, combined grants and rejected encodings. The syntax
follows the [repository permission specification](https://atproto.com/specs/permission#repo);
`putRecord` follows the reference PDS requirement for both create and update.
Granular blob, RPC, account and identity permissions are described below.
`include:` permission sets are resolved and snapshotted as described below.

### OAuth permission sets

`Atoll.OAuth.PermissionSets.resolve/2` resolves an `include:<nsid>` invocation through
the existing authenticated Lexicon fetcher: DNS namespace delegation, fresh DID/PDS
resolution, record CID verification and a signed CAR inclusion proof under the
resolved repository key. HTTPS public-address checks and fetch size/time bounds
are inherited from that fetcher. Inclusion authenticates the record under that
key; it does not prove that the signed commit is the latest. No network resolution
runs inside a database transaction.

`Atoll.OAuth.PermissionSet` validates bounded `permission-set` documents and
expands only understood repository/RPC declarations. Every referenced collection
or method must be in the set's NSID group or a child group. Wildcard resources,
sibling/parent namespaces, fixed RPC audiences, unsupported resources and unknown
permission fields grant nothing. A mixed valid/invalid declaration is ignored in
full. RPC audiences can be `*` in the document or inherited from an explicit DID
service reference on the include invocation. Missing inherited audiences grant
no permission. Titles, details and localized text are preserved and bounded.

Migration `20260927005341` stores at most 1,000 cached documents, each limited to
256 KiB encoded JSON and 256 declarations (128 resource names per declaration).
Fresh entries avoid resolution for 24 hours. Failed refreshes retain the last
verified document and back off for five minutes without renewing its original
age. New-session lookup expires at 90 days; callers resolving an existing session
may use older cached data. Expired entries can be reclaimed when adding a new
entry. Cache writes serialize briefly and do not overwrite a concurrent update.

`include:<nsid>` and `include?nsid=<nsid>` scopes are accepted at PAR, with an
optional concrete DID service `aud` parameter. Client metadata must declare the
include. Alternate string encodings are equivalent; narrowing may remove an
inherited audience but cannot replace it, add one to an audience-free grant, or
switch namespaces. Direct repository/RPC scopes cannot be manufactured from an
include by changing the refresh request's scope string.

Migration `20260927010301` adds persistent permission-set snapshots to pushed
requests, authorization codes, OAuth sessions and access tokens. PAR verifies and
admits DPoP before resolving any sets. Resolution failures do not persist a pushed
request or consume PKCE, but the admitted proof remains consumed. Unavailable sets
or cache/storage failures return a retryable HTTP 503. Requests are bounded to
16 include invocations, 1 MiB of snapshot JSON, and 256 KiB of expanded permission
strings. A 30-second total resolution budget is checked between fetches and after
resolution; individual network calls retain the existing transport timeouts.

Consent uses the PAR snapshot, with a checkbox for each include and expandable
permission details. Titles and details support bounded `Accept-Language`
preferences with regional fallback; all schema-provided text is HTML-escaped.
The screen explains that sets may change over time within their namespace. Only
selected includes are copied into the authorization code. Code exchange copies
those same documents into the session and initial token, even if the shared cache
changes between display, approval and exchange.

Resource authorization expands only the access token's own stored snapshot,
under the existing authorization locks, and performs no set resolution or shared
cache reads. Current raw token scope must remain covered by the session's original
grant. All repository, blob, RPC, account and identity checks continue to apply to
the resulting permissions; a set may grant only its validated repository/RPC
permissions. Changing or evicting the cache cannot change an issued token.

Refresh resolves selected includes outside database locks, falling back to the
session's last verified snapshot during outages or cache eviction. It rechecks
account, source-session, grant, client and refresh-token state before atomically
rotating and storing the new snapshot. Existing access tokens retain their prior
permissions. Narrowed refreshes retain fallback documents for the original grant
without including deselected sets in the new access token. Reuse of an old refresh
token still revokes the session after snapshot changes. This implements the
[permission-set token semantics](https://atproto.com/specs/permission#permission-sets).
Resolution uses the existing `:lexicon_resolution_options`; the network-record
validation opt-in does not disable explicit OAuth permission-set resolution.

### OAuth identity permissions

`identity:handle` authorizes `com.atproto.identity.updateHandle`; `identity:*`
also authorizes `requestPlcOperationSignature`, `signPlcOperation` and
`submitPlcOperation`. The full grant can be narrowed to handle-only access through
client metadata, consent and refresh. Scalar `attr` query syntax is accepted;
unknown attributes, extra parameters and repeated attributes are rejected.
Transitional generic access does not grant these operations. Consent distinguishes
handle changes from control over DID keys and migration.

DPoP proof admission precedes body parsing. Each operation receives an endpoint-
and process-bound internal credential, and current authorization is checked again
inside the existing mutation transactions. Directory and handle-resolution calls
run outside those transactions. A token narrowed or revoked during lookup cannot
authorize subsequent staging, signing or local completion. Already submitted
external operations cannot be rolled back by local revocation; the durable PLC
journal remains available for reconciliation and an authorized retry.

Existing identity safeguards still apply: bidirectional custom-handle resolution,
name reservations, verified directory history and head, local signing-key/service
compatibility, and atomic profile/identity-event updates. `did:web` handle changes
require the owner-updated DID document. PLC signing still requires a confirmed
email and a single-use code delivered by the configured Cloudflare Worker; it
returns a signature without publishing or changing local identity. OAuth requires
an active account, while legacy migration sessions retain their existing policy.
The 30-second credential expiry bounds each request; a retry requires a new proof.

The scope semantics follow the [identity permission specification](https://atproto.com/specs/permission#identity).
`GET /xrpc/com.atproto.identity.getRecommendedDidCredentials` accepts base `atproto`
OAuth scope and returns only the authenticated account's public repository signing
key, PDS service and current observed handle (falling back to the profile handle
when no observation exists). Unknown or unverified handles are omitted. It checks
key custody and holds current authorization/account locks while reading; it never
returns private keys, email or password-session credentials. Custody failures
retain their existing domain error responses. PLC rotation-key recommendations
are not currently included.

`refreshIdentity` also accepts base `atproto` scope because it only re-resolves and
publishes public identity observations; it cannot change DID keys or account
hosting. The existing owner-only, bounded-resolution and event-deduplication rules
apply. Both endpoints preserve their password-session paths, including the
existing deactivated-account migration policy.

### OAuth account permissions

`account:email` (or explicit `action=read`) exposes email and confirmation status
in `getSession`. `account:email?action=manage` includes read access and authorizes
`requestEmailUpdate`, `updateEmail`, `requestEmailConfirmation`, and `confirmEmail`.
Existing confirmation codes, expiry, cooldowns and address checks still apply;
all email delivery uses the configured Cloudflare Worker. OAuth responses omit
`emailAuthFactor`. Changing an address clears its confirmation and email factor.

`account:repo?action=manage` authorizes signed CAR import through `importRepo`.
`account:repo` alone adds no capability. Neither permission grants record writes
or blob uploads. `transition:generic` and `repo:*` do not grant account management.
The parser also accepts scalar `attr` query parameters, rejects wildcards and
unknown attributes, and permits refresh narrowing from manage to read.

Both paths admit DPoP before reading request bodies and recheck current token,
grant and source-session authorization before mutation. Internal credentials are
bound to the process and endpoint; imports allow 300 seconds for validation,
while other write credentials expire after 30 seconds. OAuth requires an active
account; legacy migration authentication retains its existing inactive-account
policy. CAR ownership, signature, captured-head and atomic import checks still
apply. The semantics follow the [account permission specification](https://atproto.com/specs/permission#account).

### DPoP blob uploads

`POST /xrpc/com.atproto.repo.uploadBlob` accepts DPoP-bound OAuth access tokens
with `atproto` and either `transition:generic` or applicable granular blob scopes.
Proof admission and declared MIME permission checks run before reading the raw
request body. An admitted proof remains consumed when size, metadata, quota, or
storage checks fail. Missing upload permission returns the OAuth
`insufficient_scope` error with HTTP 403; invalid or revoked access returns 401.

Uploads use the same signed, process-bound, 30-second internal credential as
record writes, bound specifically to `uploadBlob`. After reading the body, the
storage path rechecks the credential and then rechecks current authorization
under the repository write lock, holding account/session/access locks through
storage commit. Revocation, scope narrowing, and inactive accounts block uploads.
Record-write credentials cannot authorize blob uploads or vice versa.

The existing raw-body size/time limits, MIME detection, per-account quotas,
staged visibility, and PostgreSQL/S3 storage behavior apply to OAuth uploads.
Tests cover raw bytes, publication through an OAuth record write, pre-body proof
validation, failure replay, revocation and scope changes between the upload plug
and controller, quotas, and mocked S3 success/failure. These additions do not
change the opt-in MinIO integration tests.

### Granular blob permissions

Request `blob:image/*` to upload images, `blob:image/png` for PNG only, or
`blob:*/*` for all media types. Repeated `accept` parameters allow a union, such as
`blob?accept=image/png&accept=text/plain`. MIME patterns support a full subtype
wildcard or `*/*`; suffix globs, parameters and unknown permission fields are
rejected. Positional/query percent encoding follows repository permissions; a
literal `+` in a query value must be encoded as `%2B`. MIME matching is
case-insensitive, while resource names remain case-sensitive.

Client declarations and granted scopes can cover narrower MIME permissions in
PAR, consent and refresh. Specific types cannot expand into a subtype wildcard,
and image permissions cannot expand to all media. The consent page lists the
accepted media types and allows each requested scope to be unchecked. Blob scopes
do not authorize record writes or other protected resources.

The upload plug checks the normalized declared MIME type before body admission;
a missing Content-Type retains the `application/octet-stream` default. Under the
storage transaction's repository and authorization locks, Atoll checks current
scope against the declaration, the detected MIME type, and any existing ownership
row's MIME type. The first stored MIME for an account/CID stays authoritative.
A spoofed declaration or duplicate upload therefore cannot refresh staged metadata
or return a descriptor outside the granted types. These checks precede PostgreSQL
byte writes and S3 requests. Scope changes after body admission return HTTP 403;
retries require a new DPoP proof.

Tests cover consent selection, semantic refresh narrowing, accepted/rejected MIME
patterns, declared/detected mismatches, duplicate stored metadata, early rejection
and proof replay, and scope changes before storage. A mocked S3 transport verifies
that a denied MIME upload makes no object-storage request. Signature detection
still does not decode complete media files; full media validation remains pending.
Scope syntax follows the [blob permission specification](https://atproto.com/specs/permission#blob).

### DPoP service-token issuance

`GET /xrpc/com.atproto.server.getServiceAuth` accepts DPoP OAuth access tokens with
`atproto` and either `transition:generic` or a matching granular RPC permission.
It verifies the resource nonce, original client key,
access-token hash, configured origin and GET proof before examining delegation
parameters. Account, source-session, OAuth-session, and access-token share locks
remain held while checking the requested method, loading the repository key, and
signing. Expired, revoked, or inactive-account access cannot issue a token.

The access token's current scope controls delegation, even if its session has a
broader grant. With transitional grants, explicit `chat.bsky.*` methods additionally
require `transition:chat.bsky`; checks include case variants. A matching granular
RPC grant can authorize the requested chat method directly. Protected account-management
methods remain prohibited, and transitional OAuth cannot delegate `createAccount`
for migration. Insufficient permission returns HTTP 403 `insufficient_scope` with
a DPoP challenge. Invalid parameters, expiration, and unavailable signing custody
retain the existing XRPC errors. Proofs remain consumed after these failures.

As in the [reference transitional permission implementation](https://github.com/bluesky-social/atproto/blob/main/packages/oauth/oauth-scopes/src/scope-permissions-transition.ts),
generic scope permits a method-less service token, limited to 60 seconds. Explicit
methods may use the existing maximum one-hour lifetime. Service tokens carry no
OAuth scope or DPoP binding; receiving services must enforce the audience, method,
expiry and their own policy. Revoking OAuth access prevents future issuance but
does not revoke a JWT already issued. Granular RPC scopes follow the rules below.

Tests verify the issued JWT signature and claims, method-less lifetime, separate
chat permission and narrowed access scopes, forbidden migration/protected methods,
parameter errors, missing signing custody, proof replay, revocation, inactive
accounts and target binding. Existing legacy service-token tests remain enabled.

### Granular RPC permissions

`rpc:app.example.getFeed?aud=*` permits one method on any service.
`rpc:*?aud=did:web:api.example.com%23appview` permits all methods for the exact
`did:web:api.example.com#appview` audience. Repeated `lxm` query parameters allow
multiple methods, for example
`rpc?lxm=app.example.getFeed&lxm=app.example.getProfile&aud=*`.
A concrete permission audience must include a nonempty DID service fragment.
Unknown parameters, duplicate audiences, partial method wildcards and the fully
unrestricted `rpc:*?aud=*` are rejected. Audience and method matching is exact;
a bare DID does not match a grant naming one of its service fragments.

PAR, consent and token refresh support narrowing either axis. Every requested
method/audience pair must be covered by a single original grant: separate grants
for service A/method X and service B/method Y do not authorize service A/method Y.
A finite list of methods cannot be widened to `*`. The consent page names the
methods and service audience, or explicitly says all methods/any service.
Repository, blob and email rights are not implied by RPC permissions.

Service-token issuance checks the current access token's RPC permissions under
authorization locks before loading the signing key. A method-less request needs
wildcard method permission for its audience and retains the 60-second limit.
Method-bound tokens retain the one-hour maximum. A matching granular grant can
authorize `com.atproto.server.createAccount` for migration; transitional generic
scope alone still cannot. Explicit protected-method requests remain prohibited
regardless of granted scopes. Already issued JWTs keep the existing revocation
and recipient-validation limitations described above.

Tests cover signed audience/method claims, mismatched audiences and fragments,
method-less tokens, refresh attenuation, chat access without transitional grants,
explicit migration authorization, protected-method denial and proof replay after
permission failures. Browser consent tests exercise RPC selection alongside
repository and MIME permissions. The policy follows the
[RPC permission specification](https://atproto.com/specs/permission#rpc) and the
[reference RPC matcher](https://github.com/bluesky-social/atproto/blob/main/packages/oauth/oauth-scopes/src/scopes/rpc-permission.ts).
Request proxying enforces the same RPC policy and expands permission sets through
the frozen authorization snapshots described above.

### DPoP public exports

All currently implemented local XRPC routes have an explicit OAuth policy in
`AtollWeb.OAuthPolicyPlug`. An inventory test checks the Phoenix routes and the
firehose upgrade route so newly added endpoints must be classified. Unknown
policies deny supplied OAuth credentials by default. Proxy requests are handled
separately with their service-specific RPC permissions.

Public repository reads, sync reads, server description, identity resolution and
firehose upgrades remain available without OAuth. If an OAuth credential is
supplied, its nonce, proof signature, target/method, token binding, replay status,
active account and current session are checked before query/body processing or
upgrade. Bad or revoked credentials cannot silently fall back to anonymous access.
Successful admission grants only the ordinary public path; existing availability
and takedown checks remain in force, without inactive-owner access. Identity
resolution runs outside authorization locks. Public subscription admission does
not make its public event stream private or bind the stream lifetime to a grant.

Routes with dedicated OAuth grants keep their existing endpoint-specific checks
and final authorization rechecks. App-password/invite management, account
activation/deactivation/deletion, legacy session creation/refresh/deletion,
password reset, signing-key reservation, account creation and operator endpoints
do not accept OAuth as a replacement for their own authentication mechanisms.
A valid supplied OAuth proof is consumed and receives HTTP 403
`insufficient_scope` before body parsing or side effects; invalid credentials
receive the normal nonce/proof/token errors. Anonymous, password, recovery-code,
service-JWT migration and operator flows retain their existing policies. OAuth
signup still uses the browser `prompt=create` flow.

This includes the reference PDS exclusions for
[invite access](https://github.com/bluesky-social/atproto/blob/main/packages/pds/src/api/com/atproto/server/getAccountInviteCodes.ts)
and [deactivation](https://github.com/bluesky-social/atproto/blob/main/packages/pds/src/api/com/atproto/server/deactivateAccount.ts).
Full-profile interoperability auditing remains pending; route policy coverage does
not establish complete OAuth/client compatibility.

`com.atproto.sync.getRepo`, `listBlobs`, and `getBlob` accept DPoP access tokens.
A supplied OAuth credential is validated against its live account, source session,
OAuth session and access token, including the resource nonce, proof key, access
hash, GET method and requested route. Invalid, expired or revoked credentials
return a DPoP error; an opaque OAuth token cannot be used as a Bearer credential.
The required `atproto` scope suffices because these responses contain public data.

After authentication, the export uses the same public visibility checks as an
anonymous request: only active target repositories and currently referenced blobs
are readable. A client may read another active public repository, but cannot use
OAuth to export an inactive account or staged/unreferenced blobs. Legacy owner
JWT and operator Basic authorization retain their separate export behavior.

OAuth authorization locks are released before the public export starts; no OAuth
principal or privileged credential is passed into storage. Revocation after this
check does not interrupt an already admitted public download. Repository snapshot
locks and the existing streaming timeout still protect CAR consistency, and blob
reads retain their repository/reference checks. The download does not hold a
client session lock for its duration.

Malformed query schemas can be rejected before proof admission by the existing
XRPC query boundary. Once admitted, a proof cannot be replayed, including after
a missing-blob error. Tests cover identity-only scope, raw blob responses, CAR
roots, publication visibility, foreign active repositories, inactive targets,
revocation, replay, target binding and Bearer downgrade rejection. The legacy
export tests continue to exercise owner/operator and anonymous access.

### DPoP account inventory

`GET /xrpc/com.atproto.repo.listMissingBlobs` and
`GET /xrpc/com.atproto.server.checkAccountStatus` accept OAuth access tokens with
the base `atproto` scope. The inventory always belongs to the authenticated DID;
query parameters cannot select another account. Both routes validate the DPoP
resource nonce, key, access-token hash, method and target and consume the proof
before inventory reads. Responses retain no-store, CORS and resource nonce headers.
The existing aggregate XRPC and session-query budgets apply.

Missing-blob results use the same account ownership, metadata matching, takedown
exclusion, deduplication and exclusive CID pagination as legacy sessions. Account,
source session, OAuth grant and access-token locks remain held through the query.

Account status first validates proof and current authorization, resolves the DID
with no authorization locks held, then reacquires all four locks and rechecks
account status, token/grant/source-session expiry, bindings and scopes before
reading inventory. Revocation or expiry during remote resolution prevents the
response; the already admitted proof stays consumed. DID resolution failure still
returns `validDid: false`, as with legacy sessions. Only active accounts can use
these OAuth routes; legacy migration/status access retains its existing policy.

Tests cover identity-only scopes, cross-account isolation, missing-blob pagination
and metadata/takedown filtering, status counts, failed DID resolution, replay,
nonce challenges, target binding, Bearer downgrade rejection and revocation.
Expiry, account changes and scope changes during resolution are rechecked. An
independent-connection test confirms locks are released during resolution and held
through the final read. The supported OAuth inventory policy follows the reference
PDS implementations of
[listMissingBlobs](https://github.com/bluesky-social/atproto/blob/main/packages/pds/src/api/com/atproto/repo/listMissingBlobs.ts)
and [checkAccountStatus](https://github.com/bluesky-social/atproto/blob/main/packages/pds/src/api/com/atproto/server/checkAccountStatus.ts).

### Owner management of OAuth sessions

`Atoll.OAuth.SessionManagement.list/4` and `revoke/3` provide the internal account
UI operations for OAuth grants. Both require a live full-account access JWT;
app-password sessions, refresh JWTs and opaque OAuth credentials cannot manage
grants. Deactivated owners retain access through the existing account-management
authorization policy. The browser routes and interface are described below.

Inventory is scoped to the authenticated owner, excludes expired OAuth grants or
expired source sessions, and returns at most 100 entries (default 50). Results
are ordered by opaque session ID with an exclusive cursor. Each entry includes
only its management ID, client ID, granted scope, expiry, and whether it has a
refresh token. No token digests, source-session identifiers, proof keys or client
key bindings are exposed. Client metadata is not fetched; client IDs are untrusted
data for the future UI to escape when displaying. Pages reflect current state,
not a snapshot across requests; new random IDs can sort before a previous cursor.

Revocation reauthenticates the owner inside a transaction, follows the existing
head/source-session/PAR/session lock order, and deletes only the selected owned
grant. Foreign and absent IDs return the same success result. Database cascades
remove access tokens and used refresh markers; the parent password session and
other OAuth grants survive. Expired grants can also be revoked. Lock and database
failures return `oauth_session_store_unavailable`. Statements and lock acquisition
are bounded by the existing OAuth timeout policy.

Tests cover pagination and field minimization, owner isolation, idempotence,
source expiry, management credential restrictions, deactivated accounts, and
cascade deletion. A full token-exchange integration test confirms that owner
revocation blocks subsequent resource reads and refreshes while preserving the
owner's password session. Previously issued service JWTs remain valid until their
own expiry, subject to the receiving service's policy.

### Browser account session management

Open `/account/login` to sign in with your **account password** and email address
or DID, then view connected applications at `/account/sessions`. Email-factor
accounts must enter the code sent through the existing configured email Worker.
App passwords cannot open this account-management interface. The page lists the
client URL, granted scope, expiry and a revoke button, with pagination after 50
entries. Client strings are escaped and rendered as text without remote metadata,
images or scripts. Revocation removes only the selected owned OAuth grant.

The browser uses a separate encrypted, signed, HttpOnly `SameSite=Lax` cookie.
Its one-hour lifetime is also enforced on the server, and each management action
rechecks the underlying live full-account session. Login renews session state and
CSRF tokens. Logout revokes the browser's password session and clears its cookie;
other password sessions and independently created OAuth grants remain intact.
Cookies use `Secure` when the configured endpoint origin is HTTPS. Production
must serve the account pages over HTTPS with a stable secret key base.

All mutations use CSRF-protected POST forms. The account boundary runs before
general parsing/logging, admits only canonical routes/methods, bounds raw forms
to 8 KiB, and rejects duplicate fields. Login has a separate 10-request/five-minute
peer budget; other browser requests have a 100-request/five-minute budget through
the configured memory/PostgreSQL/Redis limiter. Responses disable caching, framing,
referrer disclosure, scripts and external resources. Query and body data never
choose a redirect destination; redirects stay on fixed account paths.

HTTP tests explicitly enable CSRF protection and cover the complete login/list/
revoke/logout flow, email and DID login, restricted credential rejection, email
factor prompts, cookie tampering, expired browser/account sessions, HTML escaping,
request limits, and invalid forms/methods. Browser OAuth consent is described below;
server discovery is described above.

### Browser OAuth authorization and consent

Clients redirect to `GET /oauth/authorize` with exactly `client_id` and
`request_uri` from the pushed authorization response. Unknown, expired, mismatched,
extra or duplicate front-channel parameters fail locally without redirecting to
an untrusted destination. Pushed requests expire after 90 seconds, or 600 seconds
for `prompt=create`, measured from admission through consent; an expired flow must
restart from the application.

The account browser stores a compact encrypted context containing the request
reference, a client-ID hash and a random form identifier. Login preserves this
context across cookie renewal and resumes consent at the fixed local endpoint.
The consent page shows the full client URL and current account DID as escaped
text, and requires an explicit Allow or Deny action. Clients always receive the
required identity scope; users can deselect additional transitional permissions.
Chat access depends on general application access. No automatic approval occurs.

A DID login hint must match the displayed account; handle hints use fresh handle
verification before display and again before submission. Approval is also bound
to that DID inside the code-issuance transaction. CSRF protection, a browser-bound
form identifier, strict form fields, live account authorization, current client
metadata/key validation and atomic pushed-request consumption all apply. The
callback, original state and issuer come exclusively from the stored request.
Existing callback query parameters are preserved except OAuth response fields,
which are replaced with the current response. Denial returns `access_denied` and
never issues a code. Validation failures remain on the PDS.

The consent page permits the registered cross-origin callback navigation by
omitting `form-action` from its CSP; scripts, frames, external resources and base
URL changes remain blocked. All rendered forms still target fixed local paths.
Responses remain uncached and use `Referrer-Policy: no-referrer`.

Grants are bound to the browser's password session. Explicit browser sign-out
revokes that session and therefore the grants authorized through it; the consent
and account pages state this behavior. Browser cookie expiry alone does not
revoke grants. Individually revoked applications and independently created grants
retain their existing behavior. Authenticator login enforcement is described below;
its enrollment and recovery screens are available at `/account/security`. Optional
passkeys are available as described below.

HTTP tests cover login resumption, permission narrowing, code exchange, a resource
read, denial, logout cascades, CSRF and form tampering, hint mismatches, expired
requests and duplicate/extra query fields. A transaction-level test verifies the
displayed account cannot be replaced during code issuance. The shared login shell
has been visually checked in desktop, mobile and dark mode; a complete browser
OAuth interoperability run remains a separate task.

### OAuth account creation (`prompt=create`)

Include `prompt=create` in the **pushed** request to `POST /oauth/par`. It is
stored with the validated request; do not add it to the front-channel authorize
URL. This starts the account-creation UI as described by the
[Prompt Create extension](https://openid.net/specs/openid-connect-prompt-create-1_0.html).
Atoll uses its ATProto authorization-code/DPoP flow, not OpenID ID tokens. Other
prompt values and combinations are currently rejected with `invalid_request`.
Authorization-server metadata advertises `prompt_values_supported: ["create"]`.

`/account/signup` uses the shared purple Tailwind account shell. It requires a
live browser-bound creation request, CSRF token and matching form identifier.
The form collects a full handle, password, optional email and invitation code.
Existing signup settings, hosted domains, invitation redemption, password rules,
encrypted signing keys and confirmed PLC registration apply. A supplied login
hint must equal the new handle before creation; consent still verifies the handle
in both directions. Existing-account DID hints cannot be used to create another
account. Client URLs and hints are escaped; credentials never appear in responses.

Even an already signed-in browser starts at account creation. Successful signup
renews the encrypted cookie and binds this request to the newly created DID;
existing accounts cannot approve it instead. Switching accounts leaves the old
account's sessions and connected applications intact. The new account must still
explicitly allow or deny permissions. Signup alone issues no authorization code.
The browser form shares the login budget of ten POST attempts per IP per five
minutes and retains the 8 KiB body bound and duplicate-field rejection.

Creation requests have a ten-minute lifetime without sliding renewal. Expired
requests cannot start signup. If directory confirmation finishes after expiry,
the account remains created and signed in, but the application must restart
sign-in; no expired consent is accepted. Directory failures can resume the
existing pending signup using exactly the same credentials, email and invitation,
subject to the existing signup recovery policy. Disabled signup returns a local
error without redirecting to the client.

Tests exercise HTTP admission (including all thirteen confidential-client fields),
invalid/duplicate prompts, complete signup/consent/code exchange, existing-login
isolation, CSRF and context tampering, invitation/hint checks, disabled signup,
directory retry, and expiry both before and during registration. The rendered signup
form has also been checked at desktop/mobile widths and in dark mode, without
horizontal overflow.

### Authenticator cryptographic primitives

`Atoll.Accounts.TOTP` implements the six-digit SHA-1/30-second profile compatible
with common authenticator applications. It generates fresh 160-bit secrets and
builds `otpauth://totp` provisioning URIs with escaped display labels, an unpadded
Base32 secret and explicit profile parameters. Labels must not contain colons or
control characters. These URIs contain secret material and must stay within the
account's enrollment flow; no external QR-image service should receive them.

Verification takes a trusted timestamp and last-used step, checks the previous,
current and next step, and returns the highest matching step newer than the
persisted value. All candidate code comparisons use `Plug.Crypto.secure_compare`.
Inputs require exactly six ASCII digits, including leading zeroes, and counters
support the full unsigned 64-bit range. Tests include the RFC 4226 counters and
RFC 6238 SHA-1 vectors (six-digit suffixes), drift boundaries, leading zeroes,
post-2038 timestamps, malformed inputs and counter overflow.

`Atoll.Accounts.TOTPSecret` seals 160-bit secrets in versioned AES-256-GCM envelopes
with fresh nonces and authenticated data binding the account DID and TOTP purpose.
It uses the existing active master key and bounded decryption-only fallback ring.
`rewrap/2` returns a fresh envelope under the active key. The persisted-key
rotation workflow also rewraps enrolled factors atomically and reports a `totp`
count. Tests cover account binding, tampering, fallback decryption and retirement.

### Persistent authenticator enrollment and login

`Atoll.Accounts.Authenticator.begin/2` requires a full account session and fresh
password. It stores an encrypted pending secret for ten minutes; `confirm/2`
enables the factor only after a valid code and consumes that code. The browser
flow at `/account/security` displays a manual setup key for Google Authenticator
and compatible apps, then requires a code to finish setup. Accounts without a
confirmed factor retain password login behavior. Passkey login is described below.

Confirmed factors require a six-digit authenticator code or a 26-character
recovery code on browser password login and on
`com.atproto.server.createSession`, using the Atoll-specific optional `totpCode`
field. If the email factor is enabled too, both factors are required. Restricted
app passwords retain their existing behavior and cannot open browser management.

PostgreSQL row locks serialize verification and persist the last consumed time
step, preventing concurrent reuse. A factor permits five submitted attempts per
five-minute window, including confirmation and successful codes; restarting
pending enrollment does not reset the limit. Admission runs in its own transaction
so failures and consumed codes survive later login failures. Password login must
therefore be called outside a caller-owned transaction; trusted provisioning may
still use `Sessions.create_for_account/2` within a transaction.

Session creation rechecks the factor version and a short-lived internal admission
under the account lock. Admission is server state, never an HTTP parameter.
Tests cover enrollment expiry, credential changes, replay, parallel connections,
attempt persistence, stale admissions, browser/API login and master-key rotation.

### Authenticator recovery and management

Confirmation returns ten random 128-bit recovery codes, displayed once in the
uncached browser response. Only account-bound SHA-256 hashes are persisted.
Enter a recovery code in the authenticator field (or XRPC `totpCode`) in place of
a current app code; the password and any enabled email factor are still required.
Recovery login consumes that code without disabling TOTP. Failed login steps
cannot restore a consumed recovery code. Recovery attempts share the same
five-attempt/five-minute database budget with ordinary codes and management.

At `/account/security`, a full account session, fresh password and unused
factor code are required to replace recovery codes or disable TOTP. Replacement
invalidates the complete old set and any outstanding login admissions. Disabling
removes the factor and its recovery codes; a new authenticator can then be enrolled.
An unfinished setup can be restarted with a fresh password. Secrets and recovery
codes are never returned by the status endpoint or stored in browser cookies.
Existing password/OAuth sessions and app passwords remain active; changing the
factor protects future password sign-ins. There is no self-service recovery if both the authenticator and all recovery
codes are lost; no email-only factor reset is provided.

### Browser styles and asset builds

Account and OAuth consent screens share a locally compiled Tailwind CSS 4.3.0
stylesheet. The compact card, neutral surfaces, field sizing and footer follow
the deployed [Witchcraft PDS](https://pds.witchcraft.systems/account) and
[selfhosted.social PDS](https://selfhosted.social/account) screens, with purple
(`#8338ec`) actions and automatic light/dark colors. Atoll retains its own name,
account fields and supported actions. `mix setup` installs the pinned CLI and builds the assets; development
runs a Tailwind watcher. Use `mix assets.build` after changes to the stylesheet or
screen markup. `mix precommit` builds assets before tests, so CI checks that the
build succeeds. Before making a production release, run `MIX_ENV=prod mix assets.deploy` to build and digest the stylesheet. Generated assets are ignored
by Git and must be included in the release. The pages load no third-party styles,
scripts, fonts or QR services. CSP permits same-origin styles; only passkey ceremony
pages additionally permit the local passkey script.

### WebAuthn verification foundation

`Atoll.Accounts.WebAuthn` verifies user-verified ES256 (P-256/SHA-256) passkey
registration with `none` attestation and discoverable-credential assertions.
The implementation uses OTP/OpenSSL for point validation and signature checks,
following [WebAuthn registration and assertion verification](https://www.w3.org/TR/webauthn-3/#sctn-rp-operations).
It accepts an exact canonical HTTPS origin and uses that origin's full host as the
RP ID; `http://localhost` with an optional port is available for local development.
Challenges contain 32 random bytes. The verifier checks ceremony type, exact
challenge/origin, RP hash, presence and verification flags, credential ID and
32-byte user handle, immutable backup eligibility, and signatures over the raw
authenticator data and client-data hash. Cross-origin frames are rejected.

Nonzero signature counters must advance; all-zero counters remain supported for
synced passkeys. The bounded WebAuthn CBOR decoder is separate from DAG-CBOR and
accepts the integer keys needed by COSE. It rejects duplicate map keys, trailing
bytes, oversized/deep structures, tags, indefinite lengths and unsupported types.
Client-data JSON rejects duplicate top-level keys. This profile does not assert
hardware provenance, accept attestation certificates, or offer other algorithms.

This verifier is connected to the persistent lifecycle and browser screens below.
Callers must supply trusted context and stored credentials; verification alone
cannot prevent challenge replay or authorize a session.

Tests include genuine `navigator.credentials.create/get` responses captured from
a Chrome CTAP2 virtual authenticator using a fresh temporary profile and no real
account. The checked-in fixture contains public ceremony data, not private keys.
To regenerate it locally with Node 22+ and Chrome/Chromium, run
`node scripts/capture_webauthn_fixture.mjs` (set `CHROME_BIN` if needed), then
`mix test test/atoll/web_authn_test.exs`. Ordinary CI uses the fixture and does not
need a browser. Tests also cover malformed inputs, altered signatures, wrong
origins, user verification, backup flags, extension framing and counter reuse.


### Persistent passkey lifecycle

`Atoll.Accounts.Passkeys` connects the WebAuthn verifier to PostgreSQL and account
sessions. It is an internal API: browser controllers must supply a random 256-bit
cookie binding, enforce CSRF and rate limits, and never accept trusted admission
state from a request. The browser adapter described below enforces these boundaries.

`begin_registration/5` requires a live full-account session, fresh password and,
when enabled, an unused authenticator or recovery code via `:totp_code`. Its
options request a discoverable, user-verified ES256 key with no attestation.
Each account receives a stable random 32-byte user handle, unrelated to its DID
or email. Accounts can register at most ten passkeys, each named with 1–64 UTF-8
bytes. Existing credentials appear in the authenticator exclusion list.

`complete_registration/4` checks the live session, account, browser, ceremony,
origin, password digest and current authenticator enrollment version. It consumes
the challenge and persists only public credential data. Credential IDs are unique
across all accounts and cannot be reassigned by enrolling an existing ID. Logout,
password recovery or operator session revocation invalidates pending enrollment.
Account deletion cascades through its user handle, keys and pending enrollments.

`begin_login/1` returns account-independent discoverable options.
`complete_login/3` verifies the assertion under the account lock, updates the
counter/backup state and consumes the challenge before issuing a full-account
session. A short-lived internal admission is rechecked for account status,
credential ownership, revocation, password replacement and endpoint origin during
session creation. Consumed proofs remain consumed when issuance hits a session
limit. Hardware or synced passkeys with user verification are an alternative to
the password and its optional email/TOTP factors; enrollment remains opt-in.

Challenges expire after five minutes, use PostgreSQL time, bind the exact endpoint
origin, and never slide their expiry. Only digests of request references and
browser bindings are persisted. A shared lock caps storage at 10,000 ceremonies;
admission reclaims at most 1,000 expired rows. Matched malformed responses consume
the challenge; a wrong browser or ceremony cannot consume someone else's request.
All lifecycle writes are bounded by lock/statement timeouts. Public ceremony
responses are not logged, and sensitive schema fields are redacted from inspection.

`list/1` returns only owner-visible management IDs, names, timestamps and backup
flags. `revoke/4` requires the live account session, fresh password and any enabled
TOTP proof. Deleting a passkey cascades through sessions created with it, including
their OAuth grants and tokens; other sessions remain intact. Operator credential
revocation also removes passkeys. Password-based sign-in with any configured
factors remains available for recovering from a lost passkey; password resets do
not themselves remove registered keys.

Set `config :atoll, :passkeys_enabled, false` or `ATOLL_PASSKEYS_ENABLED=false` to
disable new registration and login ceremonies (default `true`). The environment
overrides configuration only when supplied. Owner inventory and removal remain
available while disabled; existing sessions are not automatically revoked.

Tests cover persistence, user handles, duplicate ownership, account isolation,
password/session/factor changes, counter regression, bad signatures, expiry,
challenge/account caps, session-cap failures and cascading OAuth revocation.
Independent database connections race both enrollment and zero-counter login:
exactly one request succeeds for each shared challenge.


### Passkeys in the browser

Open **Account security → Manage passkeys** (`/account/passkeys`) after signing
in. Add a name, re-enter your password and provide an unused authenticator or
recovery code if TOTP is enabled. Choose **Continue with passkey** and follow the
device prompt. You can use a platform authenticator, a synced passkey provider or
a compatible security key; the authenticator must support discoverable ES256 keys
and user verification. Enrollment is optional and password sign-in remains available.

The login page offers **Sign in with a passkey** while passkeys are enabled.
The browser asks the authenticator to select a credential without sending an
account identifier. Successful verification renews the account cookie and resumes
any pending OAuth request at explicit consent. A passkey does not bypass
`prompt=create`, account-hint matching or permission approval. If a passkey is
lost, sign in with the password and any configured email/TOTP factor, remove the
lost key from the management page and enroll a replacement. Removing the key used
for the current browser session signs that browser out too.

All begin, finish and removal actions are CSRF-protected, canonical POST forms
sharing the ten-attempt/five-minute login budget. The encrypted cookie holds the
ceremony reference, purpose and fresh random browser binding; these are never
accepted as form parameters. Finish forms allow up to 48 KiB for WebAuthn data;
other account forms retain their 8 KiB limit. Credential JSON must contain exactly
the expected fields without duplicate keys. Invalid, expired and wrong-browser
responses fail locally. Names and public options are HTML-escaped, and passwords
are not reflected into responses.

The local `assets/js/passkeys.js` calls `navigator.credentials.create/get`,
serializes the credential and submits a same-origin form. It makes no fetch calls
and requires no npm packages. Unsupported browsers show a password fallback;
cancelled device prompts can be retried within the ceremony lifetime. Only these
ceremony pages permit `script-src 'self'`, with no inline scripts or external
resources. Framing is blocked and responses remain uncached. `mix assets.build`
copies the script into static assets; `mix assets.deploy` also fingerprints it.
Run the asset build after editing the script.

HTTP tests cover enrollment, login, password recovery, current-key revocation,
CSRF/browser binding, JSON ambiguity, escaping, expiry, disabled policy and request
bounds. An OAuth integration test confirms passkey login resumes consent and key
removal revokes the resulting grant. A real Chrome test uses a fresh temporary
profile and CTAP2 virtual authenticator to exercise the rendered forms and shipped
JavaScript, including desktop/mobile/dark rendering checks. No real credentials
or browser profiles are used.

Run `mix assets.build`, then
`mix test --include browser test/atoll_web/passkey_browser_e2e_test.exs` with Node
22+ and Chrome/Chromium (`CHROME_BIN` overrides the executable). The ordinary
suite excludes this `:browser` test; GitHub CI runs it as a separate step using
the runner's installed browser. Screenshots are written as `atoll-passkey-*.png`
in the system temporary directory. This verifies the passkey browser flow, not
complete ATProto federation or third-party client interoperability.


### OAuth client logout

`POST /oauth/revoke` accepts form-encoded `client_id`, `token`, optional
`token_type_hint`, and confidential-client assertion fields. Discovery advertises
this endpoint and its `none` / `private_key_jwt` authentication methods. As with
PAR/token, send a fresh ES256 DPoP proof with an authorization-server nonce,
targeting the configured `/oauth/revoke` URL. This endpoint has its own
20-request-per-peer/five-minute budget and shares the strict form, CORS,
no-store and pre-parser protections of the token endpoint.

An access token, current refresh token, or retained rotated refresh token can
revoke its entire OAuth grant. All access tokens and refresh history belonging
to that grant are deleted atomically; the source password/passkey session and
other grants remain. Revocation works even when the source account session has
expired or the account is deactivated. Refresh and revocation share the grant
mutation lock, so a concurrent refresh cannot leave an orphaned usable token.

Client authentication uses fresh metadata and, for confidential clients, a fresh
assertion validated against the original session key binding. Token lookup also
checks issuer, client ID and DPoP key. Unknown, foreign, mismatched-binding and
already-revoked tokens return the same HTTP 200 `{}` after proof/client admission.
Invalid proofs and client authentication still fail; replayed proofs/assertions
cannot revoke a grant. Token hints are ignored, including unknown hints, as
permitted by [RFC 7009](https://www.rfc-editor.org/rfc/rfc7009.html).
The ATProto [official OAuth client](https://github.com/bluesky-social/atproto/blob/main/packages/oauth/oauth-client/src/oauth-server-agent.ts)
uses the discovery endpoint for logout with its existing client credentials and
DPoP key. No tokens or assertions are written to application logs by this route.

