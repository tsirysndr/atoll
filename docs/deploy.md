# Production deployment runbook

A step-by-step path from an empty server to a PDS federating on the live
network, followed by the production checklist. The documents in this directory
cover every feature and option in depth; this runbook is the ordered walkthrough. Commands
assume a Linux host with systemd and a domain you control. Steps 1–8 build and
verify the server in isolation; steps 9–10 touch the live network and are
deliberately last.

Two facts shape the order of this runbook. First, Atoll refuses to boot in
production without its core secrets, so configuration comes before the first
start. Second, creating an account registers a `did:plc` identity whose
rotation keys control it permanently, so live signup comes last, after every
local check, and starts with a throwaway account.

## 1. Server, DNS, and prerequisites

- A host with a public IPv4/IPv6 address, systemd, and a non-root deploy user.
- PostgreSQL 16+ (18 recommended; backups need matching client binaries on
  PATH — `pg_dump` 14 cannot dump an 18 server).
- Elixir/OTP matching `mix.exs` on the build machine (build on the same
  OS/arch as the server, or on the server itself).
- DNS `A`/`AAAA` records for the PDS hostname (for example `pds.example.com`)
  and, if you will host user handles, a wildcard for the handle domain
  (`*.users.example.com`) pointing at the same proxy.
- Ports 80/443 reachable; the application itself listens only on localhost.

## 2. PostgreSQL

```sh
sudo -u postgres createuser --pwprompt atoll
sudo -u postgres createdb --owner=atoll atoll_prod
```

Use TLS (`?ssl=true` in `DATABASE_URL`) whenever the database is not on the
same host. The application needs an ordinary owner role; no extensions beyond
`plpgsql` are required.

## 3. Build the release

On the build machine, from a clean checkout of the exact commit you validated
in CI:

```sh
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

Copy `_build/prod/rel/atoll` to the server (for example
`/opt/atoll/releases/<git-sha>` with a `/opt/atoll/current` symlink). Record
the git commit hash; recovery sets ask for it.

## 4. Generate and store the secrets

```sh
mix phx.gen.secret            # SECRET_KEY_BASE
openssl rand -base64 32       # ATOLL_KEY_ENCRYPTION_KEY
openssl rand -base64 32       # ATOLL_SESSION_SIGNING_KEY
openssl rand -base64 32       # ATOLL_OAUTH_NONCE_SECRET
openssl rand -base64 32       # ATOLL_PDS_SIGNING_KEY (secp256k1 service key)
```

Also choose a strong `ATOLL_ADMIN_PASSWORD` for the operator endpoints.

Before anything else, put `ATOLL_KEY_ENCRYPTION_KEY` and
`ATOLL_PDS_SIGNING_KEY` in your durable secret store (and an offline copy).
The key-encryption key wraps every account's repository and PLC signing key:
if it is lost, custody in the database is unrecoverable and every hosted
identity is stranded. Back it up with the same care as the database, and keep
old keys listed in `ATOLL_PREVIOUS_KEY_ENCRYPTION_KEYS` until a rewrap
completes (see [keys.md](keys.md)).

Store the environment in a root-owned file such as `/etc/atoll/atoll.env`
with mode `0600`.

## 5. Configure the environment

Minimum viable production environment:

```sh
# Boot-required
PHX_SERVER=true
PORT=4000
DATABASE_URL=ecto://atoll:PASSWORD@localhost/atoll_prod
SECRET_KEY_BASE=...
ATOLL_KEY_ENCRYPTION_KEY=...
ATOLL_SESSION_SIGNING_KEY=...
PHX_HOST=pds.example.com
ATOLL_PDS_DID=did:web:pds.example.com
ATOLL_AVAILABLE_USER_DOMAINS=.users.example.com

# Required for a functioning PDS in practice
ATOLL_PDS_SIGNING_KEY=...        # signs /.well-known/did.json service identity
ATOLL_OAUTH_NONCE_SECRET=...     # OAuth (modern clients) is unusable without it
ATOLL_ADMIN_PASSWORD=...         # operator/admin endpoints
ATOLL_TRUSTED_PROXY_CIDRS=127.0.0.1/32   # your reverse proxy's address(es)

# Federation
ATOLL_APPVIEW_PROXY=did:web:api.bsky.app#bsky_appview
ATOLL_RELAY_URLS=https://bsky.network
ATOLL_RELAY_CRAWL_ENABLED=true
ATOLL_MOD_SERVICE_PROXY=did:plc:ar7c4by46qjdydhdevvrndac#atproto_labeler
ATOLL_REPORT_SERVICE_PROXY=did:plc:ar7c4by46qjdydhdevvrndac#atproto_labeler
ATOLL_IMAGE_CDN_URL_PATTERN=https://cdn.bsky.app/img/%s/plain/%s/%s@jpeg

# Signup policy (leave signup off until step 10)
ATOLL_SIGNUP_ENABLED=false
ATOLL_INVITE_CODE_REQUIRED=true

# Bind only to loopback when the reverse proxy shares the host
ATOLL_LISTEN_IP=127.0.0.1
```

Self-service signup refuses operational first labels (`www`, `admin`, `mail`,
`pds`, `cdn`, ...) beneath the handle domains; tune the list with
`ATOLL_RESERVED_HANDLES` (see `docs/accounts.md`).

Verify the moderation-service DIDs yourself before relying on them; service
DIDs are operator configuration, not protocol constants.

Recommended from day one: `ATOLL_METRICS_ENABLED=true`
(with monitoring from `ops/prometheus`), the background workers
(`ATOLL_BLOB_CLEANUP_ENABLED`, `ATOLL_ACCOUNT_CLEANUP_ENABLED`,
`ATOLL_IDENTITY_REFRESH_ENABLED`, `ATOLL_EVENT_RETENTION_ENABLED` with
`ATOLL_EVENT_RETENTION_SECONDS`, `ATOLL_OAUTH_KEY_CHECKS_ENABLED`), and
`ATOLL_MEDIA_VALIDATION=images`.

Optional subsystems, each documented under [docs/](./): S3 blob storage
(`ATOLL_BLOB_STORAGE=s3` plus the `ATOLL_S3_*` settings), Redis-shared rate
limits for multi-node deployments (`ATOLL_RATE_LIMIT_BACKEND=redis`,
`ATOLL_REDIS_URL`), the Cloudflare email Worker
(`ATOLL_EMAIL_WORKER_URL`/`ATOLL_EMAIL_WORKER_TOKEN` — without it email
confirmation, password reset, and email-authorized PLC signing cannot send;
a ready-to-deploy Worker lives in `ops/email-worker`),
passkeys (`ATOLL_PASSKEYS_ENABLED=true`), verified PLC resolution
(`ATOLL_PLC_RESOLUTION_MODE=audit`), quotas, cache TTLs, rate limits,
`ATOLL_PRIVACY_POLICY_URL`, `ATOLL_TERMS_OF_SERVICE_URL`, and
`ATOLL_CONTACT_EMAIL`.

## 6. Reverse proxy

For Rocksky handles, set `ATOLL_AVAILABLE_USER_DOMAINS=.rocksky.social` and
point wildcard DNS for `*.rocksky.social` at the proxy with HTTPS configured
for those hosts. Preserve the original `Host` header when proxying to Atoll.
The homepage redirects completed local accounts such as
`https://canary.rocksky.social/` to
`https://rocksky.app/profile/canary.rocksky.social` with a non-cached HTTP 302.
Only `/` redirects; `/.well-known/atproto-did` and the PDS API routes continue
to work. Unknown handles and the configured PDS host keep the PDS landing page.

TLS terminates at the proxy; Atoll listens on plain HTTP behind it, and
production releases enforce HTTPS themselves through the compile-time
`force_ssl` in `config/prod.exs` (HSTS on, localhost excluded). The proxy
must pass WebSocket upgrades (the firehose) and preserve client addresses.
Caddy does both by default:

```
pds.example.com, *.users.example.com {
	reverse_proxy 127.0.0.1:4000
}
```

The wildcard site needs either a wildcard certificate (Caddy: DNS challenge
plugin for your DNS provider) or on-demand TLS guarded by Atoll's
`GET /tls-check` endpoint, which approves only the server host and completed
hosted-handle hosts:

```
{
	on_demand_tls {
		ask http://127.0.0.1:4000/tls-check
	}
}

pds.example.com, *.users.example.com {
	tls {
		on_demand
	}
	reverse_proxy 127.0.0.1:4000
}
```

Every user handle host must serve
both `/.well-known/atproto-did` and the XRPC routes. If you use nginx
instead, enable `proxy_http_version 1.1` with `Upgrade`/`Connection` headers
for `/xrpc/com.atproto.sync.subscribeRepos`, forward `X-Forwarded-For` and
`X-Forwarded-Proto`, and allow request bodies of at least 10 MB. List the
proxy's address in `ATOLL_TRUSTED_PROXY_CIDRS` so rate limits see real client
addresses.

## 7. systemd unit

`/etc/systemd/system/atoll.service`:

```ini
[Unit]
Description=Atoll PDS
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=atoll
Group=atoll
EnvironmentFile=/etc/atoll/atoll.env
WorkingDirectory=/opt/atoll/current
ExecStartPre=/opt/atoll/current/bin/atoll eval "Atoll.Release.migrate()"
ExecStart=/opt/atoll/current/bin/atoll start
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now atoll
journalctl -u atoll -f
```

A missing required secret fails `ExecStart` immediately with a message naming
the variable — that is the boot guard working, not a packaging problem.

## 8. Smoke-test locally (no federation yet)

All of these must pass before touching the live network:

```sh
curl -s https://pds.example.com/xrpc/_health          # {"version":"..."}
curl -s https://pds.example.com/health/ready           # {"status":"ok"}
curl -s https://pds.example.com/xrpc/com.atproto.server.describeServer
curl -s https://pds.example.com/.well-known/did.json   # service identity
curl -s -u admin:$ATOLL_ADMIN_PASSWORD https://pds.example.com/metrics | head
curl -s https://pds.example.com/robots.txt
# Firehose upgrade through the proxy (expect a successful WebSocket handshake):
curl -si -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: aaaaaaaaaaaaaaaaaaaaaa==' \
  'https://pds.example.com/xrpc/com.atproto.sync.subscribeRepos?cursor=0' | head -3
```

Also confirm a wildcard host answers:
`curl -s https://anything.users.example.com/xrpc/_health`.

## 9. First live-network contact, read-only

`did:web:pds.example.com` needs no registration — publishing
`/.well-known/did.json` (step 8) is the whole ceremony. Confirm the PDS DID
resolves from outside, then verify outbound reachability to the services you
configured:

```sh
curl -s https://plc.directory/_health
curl -s https://api.bsky.app/xrpc/_health
curl -s https://bsky.network/xrpc/_health
```

Nothing has written to the network yet.

## 10. First account — throwaway first

Account creation registers a `did:plc` identity at the directory. Do this
first with an account you are prepared to abandon.

1. Issue one invite code (keep `ATOLL_INVITE_CODE_REQUIRED=true`):
   `mix atoll.invites.create` on a deploy host, or
   `POST /xrpc/com.atproto.server.createInviteCode` with the admin credential.
2. Set `ATOLL_SIGNUP_ENABLED=true` and restart.
3. Create the account with any atproto client, or:

   ```sh
   curl -s https://pds.example.com/xrpc/com.atproto.server.createAccount \
     -H 'content-type: application/json' \
     -d '{"handle":"canary.users.example.com","password":"...","inviteCode":"..."}'
   ```

4. Validate federation end to end:
   - `https://plc.directory/<did>` shows the new identity with your PDS
     endpoint.
   - `com.atproto.identity.resolveHandle` for the handle returns the DID, and
     `https://canary.users.example.com/.well-known/atproto-did` serves it.
   - Relay crawl: either wait for the periodic announcement or run
     `mix atoll.relays.request_crawl`; the durable audit records the outcome.
   - Log into the real Bluesky app against `https://pds.example.com`, post,
     upload an image, follow someone, open a custom feed, and check the
     profile appears on `bsky.app` within a minute. This exercises sessions,
     the AppView proxy, feed-generator tokens, and read-after-write against
     the live network.
5. If a submission ends ambiguously, use the PLC journal tooling
   (`mix atoll.accounts.reconcile_signup`, `mix atoll.plc.reconcile_*`)
   described in [keys.md](keys.md) rather than retrying blindly.

Only after the canary behaves for a while should real accounts, or a
migration of an identity you care about, follow — and before any migration,
run the backup and restore drill against this deployment (`ops/backup`).

## Production checklist

Boot and identity

- [ ] CI green on the deployed commit; release built from that exact commit.
- [ ] `DATABASE_URL`, `SECRET_KEY_BASE`, `ATOLL_KEY_ENCRYPTION_KEY`,
      `ATOLL_SESSION_SIGNING_KEY`, `PHX_HOST`, `ATOLL_PDS_DID` set (boot
      refuses without them); `ATOLL_PDS_SIGNING_KEY`,
      `ATOLL_OAUTH_NONCE_SECRET`, `ATOLL_ADMIN_PASSWORD` set.
- [ ] `ATOLL_KEY_ENCRYPTION_KEY` and `ATOLL_PDS_SIGNING_KEY` in durable,
      offline secret storage; environment file root-owned, mode 0600; secrets
      absent from shell history and version control.
- [ ] `/.well-known/did.json` and `/xrpc/_health` correct from the public
      internet, including a wildcard user host.

Transport

- [ ] TLS at the proxy with a valid wildcard certificate (releases enforce
      HTTPS/HSTS at compile time, localhost excluded).
- [ ] WebSocket upgrade verified through the proxy on `subscribeRepos`.
- [ ] `ATOLL_TRUSTED_PROXY_CIDRS` lists exactly the proxy addresses.
- [ ] Database connections use TLS if the database is remote.

Federation

- [ ] `ATOLL_APPVIEW_PROXY`, `ATOLL_RELAY_URLS` +
      `ATOLL_RELAY_CRAWL_ENABLED=true`, mod/report service DIDs verified and
      configured, `ATOLL_IMAGE_CDN_URL_PATTERN` set.
- [ ] Canary account created, visible on plc.directory, crawled by the relay,
      and usable from the official app (post, image, follow, custom feed).

Policy

- [ ] Signup posture chosen: disabled, or enabled with invites required.
- [ ] Repository and blob quotas reviewed
      (`ATOLL_REPO_MAX_ACCOUNT_*`, `ATOLL_BLOB_MAX_ACCOUNT_*`); rate limits
      reviewed; `ATOLL_MEDIA_VALIDATION=images` if you want structural image
      checks.
- [ ] `describeServer` metadata set: privacy policy, terms, contact email.
- [ ] Email Worker configured if accounts will use email confirmation,
      password reset, or email-authorized PLC operations.

Operations

- [ ] Background workers enabled: blob cleanup, account cleanup, identity
      refresh, event retention (with a retention window), OAuth key checks.
- [ ] `ATOLL_METRICS_ENABLED=true`; Prometheus scraping `/metrics` with the
      operator credential; alert rules and runbook from `ops/prometheus`
      loaded and firing to a real destination.
- [ ] Nightly recovery sets via `scripts/recovery_set.py` under
      `ATOLL_READ_ONLY=true` quiescence (see `ops/backup`), stored encrypted
      off-host with the deployment revision and keyring reference recorded.
- [ ] One full restore drill executed against THIS deployment's archive on an
      isolated target before real accounts depend on it.
- [ ] `journalctl` log retention configured; logs confirmed free of secrets.
- [ ] Upgrade procedure rehearsed: deploy new release directory, flip
      symlink, restart (migrations run via `ExecStartPre`); rollback is the
      previous symlink plus `Atoll.Release.rollback/2` if a migration must be
      undone.
- [ ] Multi-node only: `ATOLL_RATE_LIMIT_BACKEND=redis` with a shared Redis,
      one shared database, and every node quiesced together for backups.

Custody discipline (ongoing)

- [ ] Master-key rotation uses `mix atoll.keys.rotate_*` with previous keys
      retained until `mix atoll.keys.rewrap` completes.
- [ ] PLC journal health checked after any ambiguous directory submission
      (`atoll.plc.verify`, then the reconcile tasks as the signup-recovery
      decision tree in [accounts.md](accounts.md) directs).
- [ ] Operator actions reviewed via the moderation audit history
      (`mix atoll.moderation.history`).
