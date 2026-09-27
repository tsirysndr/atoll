# Logical database archives

`scripts/database_backup.py` provides whole-database custom-format PostgreSQL
archives and transactional restoration into a fresh database. It includes all
Atoll tables, PostgreSQL-backed blob bytes, revisions, events, replay floors,
credentials, encrypted custody, pending jobs and audit history. This is a logical
archive tool, not point-in-time recovery or a complete S3 backup system.

## Paired offline recovery sets

`scripts/recovery_set.py` wraps the database and S3 helpers into one private
directory. Stop all source writers, workers and maintenance commands and suspend
S3 lifecycle deletion before backup. For restoration, reserve an empty database
and an empty target `blobs/` prefix and keep all applications disconnected. The
`--offline` flag acknowledges these prerequisites; the tool cannot enforce them
or stop processes on other hosts.

```sh
# Set libpq connection settings and PGDATABASE for the source database.
# For S3, also set ATOLL_S3_* as described below.
python3 scripts/recovery_set.py backup /secure/backups/atoll-set \
  --offline --storage s3 --revision FULL_SOURCE_COMMIT_HASH \
  --keyring-reference offline-vault/atoll-keys-and-config-2026-09
python3 scripts/recovery_set.py verify /secure/backups/atoll-set
# Select isolated target database/bucket settings and the matching app/config.
python3 scripts/recovery_set.py restore /secure/backups/atoll-set --offline
```

Use `--storage postgres` for a deployment whose blobs are held in PostgreSQL.
Use Python 3.9+, compatible PostgreSQL clients and, for S3, the prepared Mix
project with dependencies. Run with the intended `MIX_ENV`. S3 operations use
`mix run --no-start`; no endpoint or Atoll worker starts. Verification does not
contact the database or S3, but needs `pg_restore` and the Mix project for an S3
set. The wrapper explicitly selects the S3 backend for remote operations and the
PostgreSQL backend for local-only verification, avoiding a requirement for S3
credentials just to verify an archive.

The destination must not exist. The wrapper writes `database/`, optional `s3/`,
and `recovery.json`, which binds the component manifests by SHA-256 and records
storage backend, creation time, source commit and a nonsecret keyring/config
reference. The commit hash is operator-supplied deployment metadata, not a check
of the current checkout. The keyring reference is a locator only: no encryption
keys, credentials or configuration are copied or validated. Keep those separately
and review the recorded revision/reference before restoring. Checksums detect
accidental component swaps or corruption, not malicious manifest replacement.

Backup verifies both components before completing. An ordinary failure removes
only the newly created incomplete local set; abrupt termination may leave partial
files. Verification validates the outer manifest, both component bindings, and
the underlying archive checks. Restore completes all verification, checks that
the database is empty, restores S3 objects with readback, then restores PostgreSQL
transactionally (checking emptiness again). A populated database is refused before
any S3 writes. S3 failure prevents database restoration; a later database failure
can leave a populated target bucket. No remote rollback/deletion is attempted.
Keep failed targets offline, investigate, and retry using fresh targets.

Before reporting backup or restore success, the wrapper reads all S3 ownership
rows from the offline source or restored database and checks that each CID appears
in the verified S3 index with the database's recorded byte size. This includes
staged/unpublished blobs and repeated ownership of shared objects. It streams
fixed-width metadata into a private temporary file and searches the on-disk index
with bounded memory; temporary disk space scales with ownership rows. A PostgreSQL-
only recovery set is rejected if any S3 ownership remains, even if the deployment's
default backend has been switched to PostgreSQL. Mixed PostgreSQL/S3 ownership
requires an S3 recovery set. The wrapper therefore requires the Atoll schema;
use the database primitive for generic PostgreSQL databases.

The same source/target check validates every PostgreSQL-owned blob, including
staged blobs in a deployment that also uses S3. Each ownership row must have a
stored block, matching byte size, canonical raw CID and matching SHA-256 digest.
Hashing uses PostgreSQL's built-in [binary-string SHA-256 function](https://www.postgresql.org/docs/18/functions-binarystring.html)
without an extension or exporting blob contents to the client. This scans owned
blob data in the database and adds I/O/CPU cost proportional to that data; plan
the offline interval accordingly. Missing or corrupt bytes fail the operation.

Local `verify` still needs no live database and checks archive integrity only;
it does not inspect ownership inside the dump. Restore's ownership check happens
after the database transaction commits. If it fails, both targets may be populated
and must remain offline for investigation. Coverage checks require the database
and local files to stay unchanged and do not prove that the source was quiesced
across the snapshots. Cleanup-only rows are not required ownership: an object may
already have been deleted before its cleanup job was acknowledged. Untracked
objects are still copied by the S3 archive helper. Missing blobs that a migration
has yet to import are outside this ownership check.

The directory, its ancestors and targets must remain private and unchanged by
other processes. Retain durable encrypted copies, keys and configuration outside
this helper; it does not fsync, encrypt, replicate, enforce retention or prove that
writers were actually stopped. Ownership coverage is limited to stored blob
rows; broader repository/media/application validity still needs restore drills.
Both Atoll restore drills below exercise this wrapper. Unit checks for component
pairing, failure ordering and existing-directory protection run with
`python3 scripts/test_recovery_set.py` and in push CI.

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
The offline S3 helper below copies and verifies current Atoll blob objects.
The combined PostgreSQL/MinIO drill below exercises selected application recovery
across both stores through the paired wrapper. Automatic production writer
quiescence and deployment-specific recovery validation remain unimplemented;
the main backup/restore checklist remains open.

### Archive and restore S3 blob bytes

With all writers and cleanup stopped as described above, configure the source
through `ATOLL_BLOB_STORAGE=s3` and the existing `ATOLL_S3_ENDPOINT`,
`ATOLL_S3_BUCKET`, `ATOLL_S3_REGION`, `ATOLL_S3_ACCESS_KEY_ID`,
`ATOLL_S3_SECRET_ACCESS_KEY` and optional `ATOLL_S3_SESSION_TOKEN` settings:

```sh
mix run --no-start scripts/s3_backup.exs backup /secure/backups/atoll-blobs
mix run --no-start scripts/s3_backup.exs verify /secure/backups/atoll-blobs
# Switch S3 settings to a newly created, isolated target bucket before restoring.
mix run --no-start scripts/s3_backup.exs restore /secure/backups/atoll-blobs
```

Use the same application revision and Mix environment as the recovery set. The
script starts the HTTP client's dependencies, without starting Atoll, its database
repository, endpoint or workers. Verification is local and requires no S3 requests.
Failures report only a generic error to avoid leaking request credentials or blob
contents. The internal `Atoll.Blobs.S3Archive` API raises on failure.

Backup refuses an existing destination. It writes a private directory (0700),
files (0600), a sorted CID index, and a count/checksum manifest. It enumerates every
current object under `blobs/`, including staged and untracked blobs. Every key
must be a canonical raw CID; every downloaded body must match its listed size and
CID digest. Unknown keys, corrupt data, repeated/unordered pages and objects over
Atoll's 5 MiB limit fail the backup rather than being skipped. An ordinary failure
removes the new incomplete directory; a killed process may leave partial files.
Listing requires the [lexicographic ordering of S3 general-purpose buckets](https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html);
directory buckets and unordered compatible implementations are unsupported.

Verification checks the manifest, complete index and every indexed blob with
bounded reads. Manifest/index/blob files must be regular files, and the archive
root and blobs directory must be directories, not symlinks. Keep the directory
and its ancestors private and unchanged throughout verification/restoration;
these checks do not defend against an operator concurrently replacing paths.
Unindexed extra files are ignored and are never uploaded.

Restore verifies the whole archive before contacting the target, requires an empty
`blobs/` prefix, then uploads and reads back each object to verify its CID. The
emptiness check is not a lock: keep the target exclusively reserved and offline.
A failure can leave a partially restored prefix; no remote objects are deleted
automatically, and rerunning into that nonempty prefix is refused. Investigate the
failure and retry with another empty target. Other prefixes are not inspected or
modified. Real MinIO integration covers paginated backup and restoration of empty,
binary and maximum-sized objects, and refusal of a populated target.

Only current object bytes and keys are retained: no historical versions, delete
markers, tags, ACLs, bucket policies, lifecycle rules, timestamps, encryption/KMS
settings or multipart uploads. Retain required provider configuration separately.
Checksums detect accidental corruption, not malicious archive replacement. These
files are not encrypted or fsynced; arrange durable encrypted copies and retention
externally. Pair the archive with the offline database/keyring recovery set and
verify application-level ownership and publication before reopening the PDS.

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
- A PostgreSQL-staged blob retained privately, with failed backup attempts for
  missing bytes, same-length digest corruption and a metadata-size mismatch,
  followed by repair of the synthetic data and successful recovery.
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
state, rolling-version migration compatibility, production grants,
large-database performance or point-in-time recovery. Continue to perform deployment-
specific restore drills before relying on an archive for recovery.

### Combined PostgreSQL and S3 drill

`bash scripts/test_minio.sh` also runs
`python3 scripts/test_atoll_database_backup.py --s3` against its disposable MinIO
container. Use matching PostgreSQL client binaries on PATH and a role with CREATEDB
as above. Push CI includes this drill. The `--s3` mode requires the script's
`ATOLL_MINIO_TEST_ENDPOINT`, restricted to HTTP on 127.0.0.1, and uses only fixed
test credentials. It creates separate source/target buckets named from its unique
disposable database names. Buckets are removed with the temporary MinIO container;
the Python runner removes its databases and local archives.

The fixture seeds an S3-backed published blob, an unpublished S3-staged blob, an
untracked S3 object, and a PostgreSQL-staged blob. It exercises the PostgreSQL
corruption cases above in this mixed-storage database and then proves that a
PostgreSQL-only set is refused while S3
ownership exists. It then deletes one known test object, checks that an S3 set
fails specifically for missing ownership coverage, and repairs that test object.
Both failed attempts must remove their incomplete local set. With the source
fixture process stopped, it creates and verifies
a recovery set containing the database and all three S3 objects. It first restores
only the database into the target and checks that the published blob cannot be
served from the empty target bucket, with no PostgreSQL raw-block fallback. It
then drops and recreates its own disposable target database and runs the full
recovery-set restore. After restoration it performs the schema, signature, custody, session, quota,
audit and replay checks above, retrieves the published blob, and confirms the
staged blob remains private. It also verifies untracked bytes were retained, then
publishes the staged blob in a new signed record and retrieves it publicly.

This demonstrates an offline recovery sequence with synthetic state; it does not
automatically quiesce production writers or test provider versioning/KMS retention
and every pending workflow.
