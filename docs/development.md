# Local development

Running Atoll locally and the development-only conveniences.

## Local development

Use `GET /health` for process liveness and `GET /health/ready` for PostgreSQL
connectivity readiness. Both responses disable caching. Readiness runs `SELECT 1`
with a one-second query timeout and no pool queueing, returning HTTP 200 with
`{"status":"ok"}` or HTTP 503 with `{"status":"unavailable"}`. A busy pool can
therefore report unavailable. Database errors and credentials are never included
in the response. This probe does not verify migrations, signing keys, S3, or
external identity services. Configure deployment probe intervals and failure
thresholds accordingly; it is not a complete production-readiness assessment.
The `[:atoll, :readiness, :check]` telemetry event includes `count`, `duration`
(native monotonic time units), and an `outcome` of `ready` or `unavailable`.

### Development configuration

Install Elixir / Erlang and PostgreSQL. The project declares Elixir `~> 1.17`; see `mix.exs` for dependency requirements.

Configure `Atoll.Repo` in `config/dev.exs` and `config/test.exs` for your local PostgreSQL role and credentials. Keep development and test database names separate. Configure the development server metadata under `config :atoll, :pds`.

Runtime metadata can be configured with `ATOLL_PDS_DID` and
`ATOLL_AVAILABLE_USER_DOMAINS` (comma-separated, dot-prefixed suffixes such as
`.example.com,.example.org`; empty clears the list). Suffixes are normalized to
lowercase and deduplicated. Unset values preserve development/test configuration.
Production requires an explicit `ATOLL_PDS_DID` and `PHX_HOST`; it advertises no
handle domains unless configured. `PHX_HOST` must be a DNS hostname without a
scheme, port, or path and sets Phoenix's public HTTPS URL on port 443. Existing
production database and secret-key configuration is still required.

These settings advertise metadata; the DID endpoint additionally requires a stable
server signing key and matching HTTPS public hostname. They do not provision
DNS, implement signup, or verify domain ownership. `describeServer` also reports
the enforced `blobUploadLimit` of 5,242,880 bytes. The server DID is the session JWT
audience, so changing it invalidates existing session tokens.

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

### Localhost DID development mode

`ATOLL_LOCALHOST_DIDS_ENABLED=true` enables a narrow exception in development and
test builds only. The default is false; enabling it through runtime configuration
in production fails startup, and production-compiled code cannot enable the
exception by changing application environment values.

The resolver accepts `did:web:localhost` (HTTP port 80), or an encoded port such as
`did:web:localhost%3A4000`. Ports must be canonical decimal integers from 1 to
65535; `%3a` is also accepted. Paths, credentials, query/fragment suffixes, raw
colons, numeric IP DIDs and subdomains of `.localhost` are rejected. HTTP requests
are pinned directly to `127.0.0.1`, without DNS, and retain `localhost:port` as Host.
Existing timeouts, response limits, expected-document ID checks and redirect
rejection apply. This mode does not let public domains resolve to private addresses
or permit arbitrary HTTP service endpoints.

For a development PDS running on port 4000, set
`ATOLL_PDS_DID='did:web:localhost%3A4000'`, enable the flag, and supply a stable
`ATOLL_PDS_SIGNING_KEY`. Keep the endpoint URL configured as
`http://localhost:4000`; the DID port must match it. The existing
`/.well-known/did.json` route then publishes the public service key on requests
whose host is exactly `localhost`. DID document parsing accepts a plain-HTTP PDS
origin only for literal localhost while this mode is enabled. Localhost handles
and fresh PLC signup over HTTP are not enabled by this exception.

Tests include an actual HTTP round trip to an ephemeral loopback Atoll endpoint,
plus disabled-mode, port, host, redirect and private-address rejection checks.
No running server configuration is changed by this feature's default settings.


