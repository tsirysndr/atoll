# SQLite

Atoll supports PostgreSQL (the default) and SQLite for a single-node PDS.
The Ecto adapter is selected **at build time**. Keep `ATOLL_DATABASE=sqlite`
set for every Mix command, including release builds. Switching adapters requires
recompilation and does not convert an existing database. SQLite uses its own
`_build/sqlite` directory so adapter-specific compiled artifacts stay separate.

## Development and tests

```sh
export ATOLL_DATABASE=sqlite
mix setup
mix phx.server
```

Development uses `atoll_dev.sqlite3` in the project directory. Tests use
`atoll_test.sqlite3` (with `MIX_TEST_PARTITION` appended to the filename when set).
Override the filename with `DATABASE_PATH`; use a different file for each test
partition if overriding it. Database files and journals are ignored by Git.

```sh
ATOLL_DATABASE=sqlite mix precommit
ATOLL_DATABASE=postgres mix precommit
```

SQLite sandbox cases run serially. Concurrency tests still run concurrent workers, which queue for SQLite’s
single pooled connection. PostgreSQL-only replica, row-lock, and aborted
transaction tests are excluded on SQLite.

## Production

Build with `ATOLL_DATABASE=sqlite MIX_ENV=prod mix release`. Set
`DATABASE_PATH=/absolute/path/to/atoll.sqlite3` at runtime; its parent directory
must exist and be writable by the service. Run `bin/atoll eval
'Atoll.Release.migrate()'` before starting the release. All the identity, session,
custody-key, and HTTPS settings in [deploy.md](deploy.md) still apply.

Use a persistent local filesystem, with one Atoll node owning the database.
SQLite uses WAL, foreign keys, full synchronous durability, a single-connection
pool, and a five-second busy timeout. Transactions begin with `BEGIN IMMEDIATE`
to acquire the writer lock before reading authorization or mutation state.
The pool queues contenders before they enter the native driver.
SQLite has no equivalent of PostgreSQL's per-statement timeout. Long transactions
serialize writers across the database, so PostgreSQL remains the choice for
multiple nodes, replicas, or higher write concurrency. `READ_DATABASE_URL` is
rejected with SQLite.

The existing `ATOLL_BLOB_STORAGE=postgres` value means database-backed blobs;
with this adapter those blobs live in SQLite. S3 remains supported. Likewise,
the existing `postgres` rate-limit backend value selects the primary database.
These names are retained for configuration and stored-data compatibility.

## Schema and backups

SQLite migrations live in `priv/sqlite_repo/migrations`; PostgreSQL migrations
remain in `priv/repo/migrations`. The SQLite baseline includes the schema through
PostgreSQL migration `20260927072902`, including check constraints, foreign keys,
indexes, and transactional revision-reference triggers. Add migrations for both
adapters when changing the schema. Generate SQLite migrations with
`ATOLL_DATABASE=sqlite mix ecto.gen.migration migration_name`.

The PostgreSQL backup/recovery scripts in `ops/backup` do not back up SQLite.
For a consistent live SQLite backup, use SQLite's backup command:

```sh
sqlite3 /absolute/path/to/atoll.sqlite3 ".backup '/backup/atoll.sqlite3'"
```

Alternatively, stop Atoll cleanly before copying its database files. Do not copy
only the main database file while WAL writes are active. Back up encryption and
session keys and any S3 objects with the database, as described in the deployment
guide. SQLite and PostgreSQL databases are not interchangeable restore formats.
