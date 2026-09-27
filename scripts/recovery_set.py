#!/usr/bin/env python3
"""Create, verify and restore paired offline Atoll database/blob archives."""
import argparse
import base64
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

import database_backup as database

ROOT = Path(__file__).resolve().parent.parent
FORMAT = 'atoll-recovery-set-v1'


def s3(action, directory):
    # Local verification needs no bucket configuration. Do not start Atoll.
    env = {**os.environ, 'ATOLL_BLOB_STORAGE': 'postgres' if action == 'verify' else 's3'}
    try:
        subprocess.run(['mix', 'run', '--no-start', 'scripts/s3_backup.exs', action, str(directory)],
                       cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    except (OSError, subprocess.CalledProcessError):
        raise database.BackupError(f'S3 {action} failed; check configuration and archive integrity') from None


def regular_manifest(path):
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 65536:
        raise database.BackupError('Missing or invalid recovery manifest')
    return path


def checksum(path):
    return database.digest(regular_manifest(path))[0]


def directory_check(path):
    if not path.is_dir() or path.is_symlink():
        raise database.BackupError('Recovery set directories must be real directories')


def verify(directory):
    directory_check(directory)
    try:
        manifest = json.loads(regular_manifest(directory / 'recovery.json').read_text())
    except (ValueError, UnicodeError):
        raise database.BackupError('Invalid recovery manifest') from None
    if (not isinstance(manifest, dict) or manifest.get('format') != FORMAT
            or manifest.get('storage') not in ('postgres', 's3')
            or not isinstance(manifest.get('revision'), str)
            or not re.fullmatch(r'[a-f0-9]{40}|[a-f0-9]{64}', manifest['revision'])
            or not isinstance(manifest.get('keyringReference'), str)
            or not 1 <= len(manifest['keyringReference']) <= 200):
        raise database.BackupError('Unsupported or incomplete recovery manifest')
    directory_check(directory / 'database')
    if checksum(directory / 'database' / 'manifest.json') != manifest.get('databaseManifestSha256'):
        raise database.BackupError('Database archive does not belong to this recovery set')
    if manifest['storage'] == 's3':
        directory_check(directory / 's3')
        if checksum(directory / 's3' / 'manifest.json') != manifest.get('s3ManifestSha256'):
            raise database.BackupError('S3 archive does not belong to this recovery set')
    elif 's3ManifestSha256' in manifest or (directory / 's3').exists():
        raise database.BackupError('Unexpected S3 component in PostgreSQL recovery set')
    database.verify(directory / 'database')
    if manifest['storage'] == 's3':
        s3('verify', directory / 's3')
    return manifest


def ownership_rows(output):
    # COPY streams bounded-width rows to a private temporary file, avoiding a
    # whole-database list in memory. No account identifiers are exported.
    sql = "COPY (SELECT encode(cid, 'hex'), size FROM repository_blobs WHERE backend = 's3') TO STDOUT"
    try:
        subprocess.run(['psql', '--no-password', '--dbname', database.database(),
                        '-Xq', '--set=ON_ERROR_STOP=1', '-c', sql],
                       stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.DEVNULL, check=True)
    except (OSError, subprocess.CalledProcessError):
        raise database.BackupError('Unable to read S3 ownership from the offline database') from None
    output.seek(0)


def indexed(index, count, text):
    low, high = 0, count
    while low < high:
        middle = (low + high) // 2
        index.seek(middle * 60)
        entry = index.read(60)
        if len(entry) != 60 or entry[-1:] != b'\n':
            raise database.BackupError('Invalid S3 archive index during ownership check')
        if entry[:59] < text:
            low = middle + 1
        elif entry[:59] > text:
            high = middle
        else:
            return True
    return False


def verify_postgres_blobs():
    # PostgreSQL's built-in bytea SHA-256 avoids exporting blob contents to the
    # client and needs no extension. Check both staged and published ownership.
    sql = """
    SELECT EXISTS (
      SELECT 1 FROM repository_blobs o LEFT JOIN blocks b ON b.cid = o.cid
      WHERE o.backend = 'postgres' AND CASE
        WHEN b.cid IS NULL OR b.data IS NULL THEN true
        WHEN octet_length(o.cid) <> 36
          OR substring(o.cid from 1 for 4) <> decode('01551220', 'hex') THEN true
        WHEN octet_length(b.data) <> o.size OR o.size NOT BETWEEN 0 AND 5242880 THEN true
        ELSE sha256(b.data) <> substring(o.cid from 5)
      END
    )
    """
    result = database.run('psql', '--no-password', '--dbname', database.database(),
                          '-XAt', '--set=ON_ERROR_STOP=1', '-c', sql, capture=True)
    if result.strip() != b'f':
        raise database.BackupError('Database contains missing or corrupt owned PostgreSQL blobs')


def verify_blob_coverage(directory, storage):
    # Requires prior archive verification and an offline, unchanged database.
    # Cleanup jobs are not ownership: their object may already have been deleted.
    verify_postgres_blobs()
    with tempfile.TemporaryFile() as rows:
        ownership_rows(rows)
        if storage == 'postgres':
            if rows.read(1):
                raise database.BackupError('Database owns S3 blobs; use an S3 recovery set')
            return
        index_path = directory / 's3' / 'index'
        count = index_path.stat().st_size // 60
        with index_path.open('rb') as index:
            while line := rows.readline(100):
                if not re.fullmatch(rb'[0-9a-f]{72}\t[0-9]{1,7}\n', line):
                    raise database.BackupError('Invalid S3 ownership row')
                encoded, size = line.rstrip(b'\n').split(b'\t')
                cid = bytes.fromhex(encoded.decode('ascii'))
                if cid[:4] != bytes.fromhex('01551220') or int(size) > 5 * 1024 * 1024:
                    raise database.BackupError('Invalid S3 ownership metadata')
                text = b'b' + base64.b32encode(cid).lower().rstrip(b'=')
                if not indexed(index, count, text):
                    raise database.BackupError('Recovery set is missing a database-owned S3 blob')
                blob = directory / 's3' / 'blobs' / text.decode('ascii')
                if blob.stat().st_size != int(size):
                    raise database.BackupError('S3 archive size disagrees with database ownership')


def backup(directory, storage, revision, keyring_reference):
    if (storage not in ('postgres', 's3') or not re.fullmatch(r'[a-f0-9]{40}|[a-f0-9]{64}', revision or '')
            or not keyring_reference or len(keyring_reference) > 200):
        raise database.BackupError('Backup requires storage, a full commit revision and a nonsecret keyring reference')
    database.database()
    directory.mkdir(mode=0o700)
    complete = False
    try:
        database.backup(directory / 'database')
        if storage == 's3':
            s3('backup', directory / 's3')
        manifest = {
            'format': FORMAT, 'storage': storage, 'revision': revision,
            'keyringReference': keyring_reference,
            'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'databaseManifestSha256': checksum(directory / 'database' / 'manifest.json'),
        }
        if storage == 's3':
            manifest['s3ManifestSha256'] = checksum(directory / 's3' / 'manifest.json')
        (directory / 'recovery.json').write_text(json.dumps(manifest, indent=2) + '\n')
        verify(directory)
        verify_blob_coverage(directory, storage)
        complete = True
    finally:
        if not complete:
            shutil.rmtree(directory)


def restore(directory):
    manifest = verify(directory)
    # Refuse a populated database before any S3 mutation. All targets must remain
    # offline and exclusively reserved: neither emptiness check is a writer lock.
    database.require_empty_target()
    if manifest['storage'] == 's3':
        s3('restore', directory / 's3')
    database.restore(directory / 'database')
    verify_blob_coverage(directory, manifest['storage'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['backup', 'verify', 'restore'])
    parser.add_argument('directory', type=Path)
    parser.add_argument('--offline', action='store_true',
                        help='Acknowledge all source writers or target users are stopped and S3 lifecycle deletion is suspended')
    parser.add_argument('--storage', choices=['postgres', 's3'])
    parser.add_argument('--revision', help='Full commit hash of the source deployment')
    parser.add_argument('--keyring-reference', help='Nonsecret reference to separately retained keys and configuration')
    args = parser.parse_args()
    if args.action != 'verify' and not args.offline:
        parser.error('backup and restore require --offline; this tool cannot stop writers for you')
    if args.action != 'backup' and any([args.storage, args.revision, args.keyring_reference]):
        parser.error('storage, revision and keyring reference are backup-only metadata')
    os.umask(0o077)
    # absolute() preserves the final component so symlink checks remain effective.
    directory = args.directory.absolute()
    try:
        if args.action == 'backup':
            backup(directory, args.storage, args.revision, args.keyring_reference)
        else:
            {'verify': verify, 'restore': restore}[args.action](directory)
    except (database.BackupError, OSError) as error:
        print(f'Recovery set {args.action} failed: {error}', file=sys.stderr)
        return 1
    print(f'Recovery set {args.action} completed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
