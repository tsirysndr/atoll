# Logical database archives

`scripts/database_backup.py` provides whole-database custom-format PostgreSQL
archives and transactional restoration into a fresh database. It includes all
Atoll tables, PostgreSQL-backed blob bytes, revisions, events, replay floors,
credentials, encrypted custody, pending jobs and audit history. This is a logical
archive tool, not point-in-time recovery or a complete S3 backup system.

Use Python 3.9+ and PostgreSQL client binaries compatible with the database server.
In particular, pg_dump 14 cannot dump a PostgreSQL 18 server. Put the correct
`pg_dump`, `pg_restore`, and `psql` on PATH. Configure connection settings through
libpq environment variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`,
`PGSSLMODE`, `PGSERVICE`, etc.) and a protected password file (`PGPASSFILE`).
`PGDATABASE` must explicitly name the source or target; connection URIs and
implicit database selection are rejected. The tool never starts Atoll or its
workers, prompts for a password, or prints database subprocess diagnostics that
might contain credentials.

## Create and inspect an archive

```sh
export PGDATABASE=atoll_prod
python3 scripts/database_backup.py backup /secure/backups/atoll-2026-09-27
python3 scripts/database_backup.py verify /secure/backups/atoll-2026-09-27
```

The parent directory must exist. The destination must not exist. The tool creates
it with mode 0700 and files with mode 0600, writes `database.dump` and a JSON
manifest containing the archive's SHA-256, size, UTC creation time and pg_dump
version, then checks the archive table of contents. Failures remove only the new
incomplete directory; an existing archive is never overwritten. A process killed
without cleanup may leave an incomplete directory; verify it before use.

Checksums detect accidental corruption, not malicious replacement. TOC verification
does not read every data block; only a restore drill proves the archive can be
loaded. Encrypt and replicate completed archives using your backup system, with
retention/access controls appropriate for password hashes, session state and
private account metadata. A custom-format archive is compressed, not encrypted.
The helper does not fsync artifacts, promise power-loss durability, or manage
remote copies. Do not declare a backup successful until the durable copy and a
restore drill have been verified.

pg_dump produces a consistent database snapshot while writes continue. Database
roles, tablespaces, external configuration and encryption keys are not included.
Keep the matching deployment configuration and key-encryption keyring separately,
including old keys needed by retained archives. Also retain session/OAuth nonce
and cookie secrets if existing sessions must survive restoration. Restoring older
session state can resurrect credentials revoked after the snapshot; plan session
invalidation before reopening a recovered server.

## Restore into an isolated, empty database

Keep the application and every worker disconnected from the target throughout
restoration. Create a database from template0, owned by the role that will restore
and run Atoll, using the source's encoding/locale settings:

```sh
createdb --template=template0 atoll_restore_drill
export PGDATABASE=atoll_restore_drill
python3 scripts/database_backup.py restore /secure/backups/atoll-2026-09-27
```

The helper verifies checksum/TOC first and refuses a target containing application
relations, routines, types, additional schemas or extensions other than plpgsql.
The emptiness check is not a lock against concurrent schema creation: keep the
target private and offline. Restore runs with `--single-transaction`,
`--exit-on-error`, `--no-owner`, and `--no-privileges`. It never drops or cleans an
existing database. A restore error rolls back changes made by pg_restore. Objects
belong to the restoring role; recreate required role grants and database-level
settings explicitly. Only restore trusted archives: PostgreSQL restores execute
SQL and functions from their source database.

Before starting Atoll, check migration compatibility using the exact application
revision recorded by your deployment system, key availability and decryption,
repository exports/signatures, authentication and blob retrieval. Keep email,
relay announcements, identity refresh, signup retries, key checks and destructive
cleanup workers disabled in a restore drill. Do not expose a restored clone under
the production identity. This helper does not automate that application-level
validation or production cutover.

## S3 and consistent recovery sets

An archive contains S3 ownership metadata, not S3 object bytes. For a conservative
recovery set, stop all Atoll instances, writers, maintenance commands and cleanup
workers; prevent bucket lifecycle deletion during the snapshot/copy interval.
Capture the database, the matching bucket's `blobs/` objects (including staged
objects needed by pending accounts), storage configuration and keyring as one
recovery set. Retain the original data until a restore drill succeeds. A live
bucket copy concurrent with cleanup is not a consistent recovery set.

Restore object bytes to an isolated target bucket before enabling serving or
cleanup. Preserve object keys and account for provider versioning, retention,
encryption/KMS keys and permissions. Atoll's S3 inventory can describe current
ownership but is not proof of a complete backup or permission to delete objects.
Automated bucket snapshot/copy, object integrity verification, and cross-store
restore drills remain unimplemented; the main backup/restore checklist remains
open. The PostgreSQL Atoll-schema drill below covers selected application state.

## Test the primitive

```sh
# Uses disposable databases only; the connected role needs CREATEDB.
PATH=/path/to/postgresql-18/bin:$PATH python3 scripts/test_database_backup.py
```

This test creates two unique databases and removes only those it created. It
checks binary data, indexes, sequence continuation, private file permissions,
refusal to overwrite a backup or populated target, checksum rejection, extra-schema
rejection, and transaction rollback for a readable archive with truncated data.
It does not read or back up development/production databases. Push CI runs both
this check and the Atoll schema drill below against its PostgreSQL 18 service,
using PostgreSQL 18 archive clients. They remain separate from `mix precommit`
and can also be run manually with the commands in this runbook.

PostgreSQL references: [pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html),
[pg_restore](https://www.postgresql.org/docs/18/app-pgrestore.html), and
[backup methods](https://www.postgresql.org/docs/18/backup.html).

## Atoll schema and application-data drill

```sh
# Existing Mix dependencies and PostgreSQL 18 clients are required.
# Use explicit PGHOST/PGPORT/PGUSER/PGPASSWORD settings for the local test server.
PATH=/path/to/postgresql-18/bin:$PATH python3 scripts/test_atoll_database_backup.py
```

This separate integration check creates two uniquely named disposable databases,
runs every Atoll migration in the source, seeds synthetic application data, archives
it, restores into the empty target, and verifies using Atoll's application modules
in a fresh process. It removes only the databases and temporary files it created.
It starts only the repository and its dependencies: no endpoint, background worker,
email or relay service runs. It does not use development or production databases.
The Elixir fixture rejects database names outside the disposable-test naming format.
Unlike libpq's archive tool, the fixture uses explicit Postgrex connection settings;
PGSERVICE, PGPASSFILE and libpq SSL options are not fixture configuration.

The drill verifies:

- Preserved migration count and a byte-identical CAR export whose signature and
  repository tree validate with the original public key.
- Decryption of the retained repository signing key, with failure under the wrong
  encryption key before successful recovery with the original key.
- Password verification, an existing access token, and refresh-token rotation.
- Published PostgreSQL blob bytes and CID verification, retained quota accounting,
  and operator audit rows.
- A nonzero replay floor, rejection of an older cursor, and encoding of retained
  event frames.
- A new signed write after restore, exercising restored indexes/triggers and
  sequence advancement beyond the pre-backup event sequence.

The fixture's encryption/session secrets are random, ephemeral environment values;
its comparison file includes synthetic session tokens and is mode 0600 inside a
private temporary directory. Neither is included in the archive. The runner reports
only failure stages to avoid printing credentials in exception values. Matching
keys remain a separately retained requirement for real recovery.

This is selected application coverage, not proof of every pending PLC/OAuth/signup
state, S3 recovery, rolling-version migration compatibility, production grants,
large-database performance or point-in-time recovery. Continue to perform deployment-
specific restore drills before relying on an archive for recovery.
