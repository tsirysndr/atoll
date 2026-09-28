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
| Docker           | Optional; `ghcr.io/tsirysndr/atoll-pds` is a prebuilt SQLite image         |

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

## Run with Docker

`ghcr.io/tsirysndr/atoll-pds` is built from the repository `Dockerfile` with the
SQLite adapter, so it is a single-node PDS: exactly one container may write to a
given database. Images are published for `linux/amd64` and `linux/arm64` on every
`v*` tag and on manual dispatch, tagged `latest`, the version, and the commit
SHA.

```sh
docker pull ghcr.io/tsirysndr/atoll-pds:latest
docker build -t atoll-pds .            # the same image, from a checkout
```

The container listens on port 4000, runs as uid 65534, keeps the database at
`DATABASE_PATH` (`/data/atoll.sqlite3` by default), and runs migrations before
starting the release. Put the boot-required variables in an env file — at
minimum `SECRET_KEY_BASE`, `ATOLL_KEY_ENCRYPTION_KEY`,
`ATOLL_SESSION_SIGNING_KEY`, `PHX_HOST`, `ATOLL_PDS_DID`, and
`ATOLL_AVAILABLE_USER_DOMAINS` — and start it:

```sh
docker volume create atoll-data

docker run -d --name atoll \
  --env-file atoll.env \
  --publish 127.0.0.1:4000:4000 \
  --volume atoll-data:/data \
  ghcr.io/tsirysndr/atoll-pds:latest
```

`ATOLL_DATABASE=sqlite` is compiled into the image and boot refuses to start if
it is changed; `DATABASE_URL` and `READ_DATABASE_URL` do not apply. Everything
else in [Setup environment](setup-environment.md) does, including TLS
termination at a reverse proxy in front of the container.

### Mount a volume at `/data`

`/data` is the only writable state in the image and holds the whole PDS:
`atoll.sqlite3`, its `-wal` write-ahead log, and its `-shm` shared-memory index.
Without a mount they live in the container's own layer and are destroyed with
it, losing every account, repository, and signing key. With the default
`ATOLL_BLOB_STORAGE=postgres` (database-backed blobs) uploads grow this volume
too, so size it for the blob quotas you allow.

A named volume is the simplest durable choice; `docker volume inspect
atoll-data` locates it on the host. For a bind mount, create the directory and
give it to uid 65534 first, otherwise the entrypoint exits reporting an
unwritable `DATABASE_PATH`:

```sh
sudo install -d -o 65534 -g 65534 -m 0750 /srv/atoll
docker run -d --name atoll --env-file atoll.env \
  --publish 127.0.0.1:4000:4000 \
  --volume /srv/atoll:/data \
  ghcr.io/tsirysndr/atoll-pds:latest
```

Point `DATABASE_PATH` at another filename inside the mount if you prefer, for
example `DATABASE_PATH=/data/pds.sqlite3`; keep it under `/data`, since a path
elsewhere is not persisted. Exactly one container may run against one volume —
SQLite has a single writer, and replacing a container means stopping the old one
first.

Back up the volume as described in [SQLite](sqlite.md). The image has no
`sqlite3` binary, so run `.backup` from the host against the volume directory,
or stop the container and copy all three files together. Back up
`ATOLL_KEY_ENCRYPTION_KEY` with it; the database is unusable without that key.

### Other container commands

Any release command works as the container command, and
`ATOLL_SKIP_MIGRATIONS=true` leaves migrations to a separate run:

```sh
docker run --rm --env-file atoll.env --volume atoll-data:/data \
  ghcr.io/tsirysndr/atoll-pds:latest eval 'Atoll.Release.migrate()'
```

The image ships a release, not Mix, so the `mix atoll.*` maintenance tasks in
[Operations](operations.md) are unavailable inside it. Run them from a checkout
built with `ATOLL_DATABASE=sqlite` against the same database file.

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
