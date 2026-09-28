# Installation

What Atoll needs on a machine, how to install it for development, and how to
build the release you ship to a server.

## Requirements

| Component        | Requirement                                                               |
| ---------------- | ------------------------------------------------------------------------- |
| Elixir           | `~> 1.17` (declared in `mix.exs`)                                         |
| Erlang/OTP       | The version your Elixir build targets                                     |
| PostgreSQL       | 16 or newer; 18 recommended                                               |
| SQLite           | Optional alternative to PostgreSQL, single node only                      |
| Node-free assets | Assets build through `mix assets.build`; no Node.js toolchain is required |

Backups need matching PostgreSQL client binaries on `PATH`: `pg_dump` 14 cannot
dump an 18 server.

## Install the toolchain

Install Elixir and Erlang/OTP with your platform's package manager or a version
manager such as `asdf` or `mise`. Verify both:

```sh
elixir --version
```

### PostgreSQL

Install PostgreSQL 16+ and create a role and database. For a production host:

```sh
sudo -u postgres createuser --pwprompt atoll
sudo -u postgres createdb --owner=atoll atoll_prod
```

Atoll needs an ordinary owner role; no extensions beyond `plpgsql` are
required. Use TLS (`?ssl=true` in `DATABASE_URL`) whenever the database is not
on the same host.

### SQLite

SQLite is supported for a single-node PDS. The adapter is chosen **at build
time**, so `ATOLL_DATABASE=sqlite` must be set for every Mix command including
release builds. Switching adapters requires recompilation and does not convert
an existing database; SQLite uses its own `_build/sqlite` directory so
adapter-specific artifacts stay separate. See [SQLite](sqlite.md) for the
durability and concurrency trade-offs.

## Install the project

```sh
git clone https://github.com/tsirysndr/atoll.git
cd atoll
mix setup
```

`mix setup` expands to `deps.get`, `ecto.create`, `ecto.migrate`, the seed
script, and `assets.setup` + `assets.build`.

Development uses `atoll_dev.sqlite3` in the project directory when the SQLite
adapter is selected; tests use `atoll_test.sqlite3`, with `MIX_TEST_PARTITION`
appended when it is set. Override the filename with `DATABASE_PATH`, using a
different file per test partition. Database files and journals are ignored by
Git.

## Build a production release

Build from a clean checkout of the exact commit you validated in CI, on the same
OS and architecture as the server (or on the server itself):

```sh
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

For SQLite:

```sh
ATOLL_DATABASE=sqlite MIX_ENV=prod mix release
```

Copy `_build/prod/rel/atoll` to the server — for example
`/opt/atoll/releases/<git-sha>` with a `/opt/atoll/current` symlink. Record the
git commit hash; recovery sets ask for it.

## Migrate and start

Run migrations before starting the release:

```sh
bin/atoll eval 'Atoll.Release.migrate()'
```

With SQLite, set `DATABASE_PATH` to an absolute path whose parent directory
exists and is writable by the service account.

## Next steps

- [Setup environment](setup-environment.md) — the variables the release reads
  at boot.
- [Production deployment](deploy.md) — secrets, reverse proxy, systemd, smoke
  tests, and the production checklist.
- [Key custody and recovery](keys.md) — back up `ATOLL_KEY_ENCRYPTION_KEY`
  before you create a single account.
