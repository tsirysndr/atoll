# Get started

Run Atoll on your own machine, confirm it answers, and know where to go next.
This page is the short path; [Installation](installation.md) covers the
toolchain in detail and [Production deployment](deploy.md) is the ordered
runbook for a real server.

## Before you begin

You need Elixir and Erlang/OTP (the project declares Elixir `~> 1.17`; see
`mix.exs`) and one database: PostgreSQL, or SQLite for a single-node server.
See [Installation](installation.md) if either is missing.

## 1. Get the source

```sh
git clone https://github.com/tsirysndr/atoll.git
cd atoll
```

## 2. Configure the database

Configure `Atoll.Repo` in `config/dev.exs` and `config/test.exs` for your local
PostgreSQL role and credentials. Keep the development and test database names
separate.

To use SQLite instead, export `ATOLL_DATABASE=sqlite` and skip the PostgreSQL
credentials. The Ecto adapter is selected **at build time**, so the variable has
to be set for every Mix command in the session:

```sh
export ATOLL_DATABASE=sqlite
```

## 3. Install dependencies and create the database

```sh
mix setup
```

`mix setup` runs `deps.get`, `ecto.create`, `ecto.migrate`, the seed script, and
the asset build.

## 4. Start the server

```sh
mix phx.server
```

The server listens on <http://localhost:4000>.

## 5. Check that it answers

In another terminal:

```sh
curl http://localhost:4000/health
curl http://localhost:4000/xrpc/com.atproto.server.describeServer
```

`GET /health` reports process liveness and `GET /health/ready` reports database
connectivity. The development server description currently returns:

```json
{"did":"did:web:localhost","availableUserDomains":[]}
```

## 6. Run the checks

```sh
mix precommit
```

`mix precommit` compiles with `--warnings-as-errors`, checks for unused
dependency locks, formats, builds assets, and runs the full default test suite.
Opt-in suites (`minio`, `redis`, `browser`, `interop`) are described in
[Testing and drills](testing.md).

With SQLite, run the suite for each adapter you support:

```sh
ATOLL_DATABASE=sqlite mix precommit
ATOLL_DATABASE=postgres mix precommit
```

## Next steps

- [Setup environment](setup-environment.md) — the configuration values that
  turn a development server into a usable one.
- [Local development](development.md) — dev-only conveniences, including
  localhost DID mode for running a PDS at `did:web:localhost%3A4000`.
- [Accounts](accounts.md) — signup, invites, app passwords, and deletion.
- [Production deployment](deploy.md) — when you are ready for a real host.

Production boot refuses to start without the database, cookie, key-encryption,
and session secrets, so misconfiguration fails at startup rather than on first
use. Creating an account on the live network registers a `did:plc` identity
whose rotation keys control it permanently — do that last, and with a throwaway
account first.
