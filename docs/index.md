---
layout: layouts/home.vto
title: Atoll PDS
description: An AT Protocol Personal Data Server built with Elixir, Phoenix, and PostgreSQL or SQLite.
---

Atoll provides account hosting, signed repositories, blob storage, the
repository firehose, OAuth, moderation tooling, and operator workflows,
tracking the endpoint surface of the pinned reference implementation.
Interoperability is exercised against pinned official client, OAuth SDK, and
firehose implementations; validate live-network federation for your own
deployment.

<div class="card-grid">
  <a class="card" href="/get-started/">
    <h3>Get started →</h3>
    <p>Clone the repository, boot a development server, and make your first request in a few minutes.</p>
  </a>
  <a class="card" href="/installation/">
    <h3>Installation →</h3>
    <p>Elixir, OTP, and database prerequisites, plus building a production release.</p>
  </a>
  <a class="card" href="/setup-environment/">
    <h3>Setup environment →</h3>
    <p>Every environment variable that shapes a deployment, grouped by what it does.</p>
  </a>
  <a class="card" href="/deploy/">
    <h3>Production deployment →</h3>
    <p>The ordered runbook from an empty server to a PDS federating on the live network.</p>
  </a>
</div>

## What is in the box

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

## Where to go next

| If you want to                            | Read                                      |
| ----------------------------------------- | ----------------------------------------- |
| Run Atoll locally for the first time      | [Get started](get-started.md)             |
| Install the toolchain and build a release | [Installation](installation.md)           |
| Understand a configuration value          | [Setup environment](setup-environment.md) |
| Take a server to production               | [Production deployment](deploy.md)        |
| Know exactly what is implemented          | [Feature record](features.md)             |

## Protocol references

- [AT Protocol overview](https://atproto.com/guides/overview)
- [Data model and CID formats](https://atproto.com/specs/data-model)
- [Repository format](https://atproto.com/specs/repository)
- [Synchronization](https://atproto.com/specs/sync)
- [OAuth](https://atproto.com/specs/oauth)
