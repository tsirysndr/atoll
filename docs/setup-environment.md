# Setup environment

Atoll is configured through environment variables. This page groups them by what
they do, from the four secrets that gate boot to the optional subsystems. The
[production deployment runbook](deploy.md) walks the same ground in order;
use this page when you need to look one value up.

Store the environment in a root-owned file such as `/etc/atoll/atoll.env` with
mode `0600`.

## Generate the secrets

```sh
mix phx.gen.secret            # SECRET_KEY_BASE
openssl rand -base64 32       # ATOLL_KEY_ENCRYPTION_KEY
openssl rand -base64 32       # ATOLL_SESSION_SIGNING_KEY
openssl rand -base64 32       # ATOLL_OAUTH_NONCE_SECRET
openssl rand -base64 32       # ATOLL_PDS_SIGNING_KEY (secp256k1 service key)
```

Also choose a strong `ATOLL_ADMIN_PASSWORD` for the operator endpoints.

Put `ATOLL_KEY_ENCRYPTION_KEY` and `ATOLL_PDS_SIGNING_KEY` in a durable secret
store, with an offline copy, before anything else. The key-encryption key wraps
every account's repository and PLC signing key: if it is lost, custody in the
database is unrecoverable and every hosted identity is stranded. Back it up with
the same care as the database, and keep old keys listed in
`ATOLL_PREVIOUS_KEY_ENCRYPTION_KEYS` until a rewrap completes — see
[Key custody and recovery](keys.md).

## Required to boot

Production refuses to start without these, so misconfiguration fails at startup
rather than on first use.

```sh
PHX_SERVER=true
PORT=4000
DATABASE_URL=ecto://atoll:PASSWORD@localhost/atoll_prod
SECRET_KEY_BASE=...
ATOLL_KEY_ENCRYPTION_KEY=...
ATOLL_SESSION_SIGNING_KEY=...
PHX_HOST=pds.example.com
ATOLL_PDS_DID=did:web:pds.example.com
ATOLL_AVAILABLE_USER_DOMAINS=.users.example.com
```

`PHX_HOST` must be a DNS hostname with no scheme, port, or path; it sets
Phoenix's public HTTPS URL on port 443. `ATOLL_AVAILABLE_USER_DOMAINS` is a
comma-separated list of dot-prefixed suffixes such as
`.example.com,.example.org`; values are lowercased and deduplicated, and an
empty value clears the list. Production advertises no handle domains unless
this is set.

The server DID is the session JWT audience, so changing `ATOLL_PDS_DID`
invalidates existing session tokens.

## Required in practice

A server boots without these but is not a working PDS.

```sh
ATOLL_PDS_SIGNING_KEY=...                 # signs /.well-known/did.json service identity
ATOLL_OAUTH_NONCE_SECRET=...              # OAuth (modern clients) is unusable without it
ATOLL_ADMIN_PASSWORD=...                  # operator/admin endpoints
ATOLL_TRUSTED_PROXY_CIDRS=127.0.0.1/32    # your reverse proxy's address(es)
ATOLL_LISTEN_IP=127.0.0.1                 # bind to loopback when the proxy shares the host
```

## Federation

```sh
ATOLL_APPVIEW_PROXY=did:web:api.bsky.app#bsky_appview
ATOLL_RELAY_URLS=https://bsky.network
ATOLL_RELAY_CRAWL_ENABLED=true
ATOLL_MOD_SERVICE_PROXY=did:plc:ar7c4by46qjdydhdevvrndac#atproto_labeler
ATOLL_REPORT_SERVICE_PROXY=did:plc:ar7c4by46qjdydhdevvrndac#atproto_labeler
ATOLL_IMAGE_CDN_URL_PATTERN=https://cdn.bsky.app/img/%s/plain/%s/%s@jpeg
```

Verify the moderation-service DIDs yourself before relying on them; service DIDs
are operator configuration, not protocol constants. See
[Operations](operations.md) for relays and proxying.

## Signup policy

```sh
ATOLL_SIGNUP_ENABLED=false
ATOLL_INVITE_CODE_REQUIRED=true
```

Leave signup off until the server is otherwise verified. Self-service signup
refuses operational first labels (`www`, `admin`, `mail`, `pds`, `cdn`, …)
beneath the handle domains; tune the list with `ATOLL_RESERVED_HANDLES`. See
[Accounts](accounts.md).

## Recommended from day one

```sh
ATOLL_METRICS_ENABLED=true
ATOLL_BLOB_CLEANUP_ENABLED=true
ATOLL_ACCOUNT_CLEANUP_ENABLED=true
ATOLL_IDENTITY_REFRESH_ENABLED=true
ATOLL_EVENT_RETENTION_ENABLED=true
ATOLL_EVENT_RETENTION_SECONDS=...
ATOLL_OAUTH_KEY_CHECKS_ENABLED=true
ATOLL_MEDIA_VALIDATION=images
```

Pair metrics with the alert rules and runbook in
[`ops/prometheus`](../ops/prometheus/README.md).

## Database

```sh
DATABASE_URL=ecto://atoll:PASSWORD@host/atoll_prod?ssl=true
POOL_SIZE=10
ECTO_IPV6=true
```

### Optional read replica

Leave `READ_DATABASE_URL` unset to use the primary for all database access. To
enable a separate read pool:

```sh
READ_DATABASE_URL=ecto://atoll_reader:PASSWORD@replica.example.com/atoll_prod?ssl=true
READ_POOL_SIZE=10
```

`READ_POOL_SIZE` defaults to `POOL_SIZE`, or 10 when neither is set. The reader
uses the same `ECTO_IPV6` setting as the primary. Provision replication
separately; Atoll does not create or manage PostgreSQL replicas. `READ_DATABASE_URL`
is rejected with SQLite. The replica semantics — what stays on the primary, and
where replication lag is visible — are documented in the
[deployment runbook](deploy.md).

### SQLite

```sh
ATOLL_DATABASE=sqlite
DATABASE_PATH=/absolute/path/to/atoll.sqlite3
```

`ATOLL_DATABASE` is read at build time as well as at runtime. See
[SQLite](sqlite.md).

## Optional subsystems

| Subsystem                | Variables                                                                       |
| ------------------------ | ------------------------------------------------------------------------------- |
| S3 blob storage          | `ATOLL_BLOB_STORAGE=s3` plus the `ATOLL_S3_*` settings                          |
| Redis-shared rate limits | `ATOLL_RATE_LIMIT_BACKEND=redis`, `ATOLL_REDIS_URL`                             |
| Email worker             | `ATOLL_EMAIL_WORKER_URL`, `ATOLL_EMAIL_WORKER_TOKEN`                            |
| Passkeys                 | `ATOLL_PASSKEYS_ENABLED=true`                                                   |
| Verified PLC resolution  | `ATOLL_PLC_RESOLUTION_MODE=audit`                                               |
| Key rotation             | `ATOLL_PREVIOUS_KEY_ENCRYPTION_KEYS`                                            |
| Policy links             | `ATOLL_PRIVACY_POLICY_URL`, `ATOLL_TERMS_OF_SERVICE_URL`, `ATOLL_CONTACT_EMAIL` |

Without the email worker, email confirmation, password reset, and
email-authorized PLC signing cannot send; a ready-to-deploy Cloudflare Worker
lives in [`ops/email-worker`](../ops/email-worker/README.md). Quotas, cache TTLs,
and rate limits are covered in [Operations](operations.md).

## Development

`ATOLL_PDS_DID` and `ATOLL_AVAILABLE_USER_DOMAINS` also apply in development;
unset values preserve the development and test configuration under
`config :atoll, :pds`. For a development PDS on port 4000:

```sh
ATOLL_LOCALHOST_DIDS_ENABLED=true
ATOLL_PDS_DID='did:web:localhost%3A4000'
ATOLL_PDS_SIGNING_KEY=...
```

`ATOLL_LOCALHOST_DIDS_ENABLED` works in development and test builds only;
enabling it through runtime configuration in production fails startup. See
[Local development](development.md) for what the exception does and does not
allow.
