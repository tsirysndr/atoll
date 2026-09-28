# Atoll

[![ci](https://github.com/tsirysndr/atoll/actions/workflows/test.yml/badge.svg)](https://github.com/tsirysndr/atoll/actions/workflows/test.yml)
[![nix](https://github.com/tsirysndr/atoll/actions/workflows/nix.yml/badge.svg)](https://github.com/tsirysndr/atoll/actions/workflows/nix.yml)

An AT Protocol Personal Data Server (PDS), built with Elixir, Phoenix, and PostgreSQL or SQLite.

Docs: **<https://atoll-docs.tsirysndr.deno.net>**

Atoll provides account hosting, signed repositories, blob storage, the
repository firehose, OAuth, moderation tooling, and operator workflows,
tracking the endpoint surface of the pinned reference implementation.
Interoperability is exercised against pinned official client, OAuth SDK, and
firehose implementations; validate live-network federation for your own
deployment.

## Table of contents

- [Highlights](#highlights)
- [Quick start (development)](#quick-start-development)
- [Deploying to production](#deploying-to-production)
- [Documentation](#documentation)
- [Testing](#testing)
- [Protocol references](#protocol-references)
- [License](#license)

## Highlights

- Complete `com.atproto` server, repo, sync, identity, and admin endpoint
  surface at the pinned upstream revision, with lexicon-validated requests.
- Signed repositories (secp256k1 and P-256) with MST inclusion proofs,
  CAR export/import, historical versions, and account migration in and out.
- `com.atproto.sync.subscribeRepos` firehose with durable, strictly ordered
  events, cursor replay, and bounded retention.
- Fresh `did:plc` signup, invites, handle domains, custom-domain handles,
  and durable PLC journals with operator reconciliation and recovery tooling.
- ATProto OAuth authorization and resource server: PAR, DPoP, granular
  permissions and permission sets, browser consent, passkeys, and TOTP.
- AppView/feed-generator/notification proxying with phase-1 service-auth
  audiences and read-after-write splicing of not-yet-indexed local writes.
- Blob storage in PostgreSQL or S3, quotas, takedowns, cleanup workers, and
  opt-in structural media validation.
- Operations: Prometheus metrics with CI-tested alert rules, read-only
  maintenance mode, paired database/S3 recovery sets with restore drills,
  and encrypted signing-key custody with rotation workflows.

## Quick start (development)

Requires Elixir/OTP (see `mix.exs`) and PostgreSQL, or use [SQLite](docs/sqlite.md) for a single-node server.

```sh
mix setup        # deps, database, assets
mix phx.server   # http://localhost:4000
mix precommit    # compile --warnings-as-errors, format, full test suite
```

Development conveniences (localhost DIDs, dev configuration) are described in
[docs/development.md](docs/development.md).

## Deploying to production

Follow the step-by-step runbook in **[docs/deploy.md](docs/deploy.md)**: server
and DNS prerequisites, secrets, configuration, reverse proxy, systemd,
smoke tests, first live-network contact, and the production checklist.
Production boot refuses to start without the database, cookie,
key-encryption, and session secrets, so misconfiguration fails at startup
rather than on first use.

## Documentation

The documentation site at <https://atoll-docs.tsirysndr.deno.net> renders the
pages below, with search and navigation.

| Document                                                 | Contents                                                               |
| -------------------------------------------------------- | ---------------------------------------------------------------------- |
| [docs/deploy.md](docs/deploy.md)                         | Step-by-step production deployment and the production checklist        |
| [docs/frontend.md](docs/frontend.md)                     | The React account frontend: stack, screens, translations, CSP          |
| [docs/features.md](docs/features.md)                     | The complete feature record with scope notes and design decisions      |
| [docs/accounts.md](docs/accounts.md)                     | Signup, invites, email, app passwords, deletion, preferences, recovery |
| [docs/identity.md](docs/identity.md)                     | DID/handle resolution, PLC submission, journals, identity changes      |
| [docs/keys.md](docs/keys.md)                             | Encrypted key custody, rotation, PLC recovery and reconciliation       |
| [docs/oauth.md](docs/oauth.md)                           | OAuth server, granular permissions, passkeys, TOTP                     |
| [docs/repository.md](docs/repository.md)                 | Lexicon discovery, inclusion proofs, CAR internals                     |
| [docs/moderation.md](docs/moderation.md)                 | Operator endpoints, takedowns, audit history                           |
| [docs/operations.md](docs/operations.md)                 | Monitoring, rate limits, retention, relays, proxying, maintenance mode |
| [docs/development.md](docs/development.md)               | Local development and dev-only behavior                                |
| [docs/testing.md](docs/testing.md)                       | Opt-in integration suites, interoperability checks, restore drills     |
| [ops/backup/README.md](ops/backup/README.md)             | Backup, recovery sets, and restore runbook                             |
| [ops/email-worker/README.md](ops/email-worker/README.md) | Deployable Cloudflare email Worker                                     |
| [ops/prometheus/README.md](ops/prometheus/README.md)     | Alert rules and operator runbook                                       |

## Testing

`mix precommit` runs the full default suite. Opt-in categories (`minio`,
`redis`, `browser`, `interop`) cover S3 integration, shared rate limits, a
real-browser passkey flow, and the official ATProto client/OAuth SDK/firehose
suites; see [docs/testing.md](docs/testing.md) for how to run each.

## Protocol references

- [AT Protocol overview](https://atproto.com/guides/overview)
- [Data model and CID formats](https://atproto.com/specs/data-model)
- [Repository format](https://atproto.com/specs/repository)
- [Synchronization](https://atproto.com/specs/sync)
- [OAuth](https://atproto.com/specs/oauth)

## License

[MIT](LICENSE)
