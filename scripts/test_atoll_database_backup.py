#!/usr/bin/env python3
"""Restore Atoll's complete migrated schema and synthetic data in disposable databases."""
import getpass
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import uuid

if sys.argv[1:] not in ([], ['--s3']):
    raise SystemExit('Usage: test_atoll_database_backup.py [--s3]')
s3 = sys.argv[1:] == ['--s3']

ROOT = Path(__file__).resolve().parent.parent
names = ['atoll_backup_test_' + uuid.uuid4().hex for _ in range(2)]
created = []
env = {**os.environ, 'MIX_ENV': 'test', 'PGUSER': os.environ.get('PGUSER', getpass.getuser()),
       'ATOLL_BACKUP_DRILL_SECRET': secrets.token_hex(32),
       'ATOLL_BACKUP_DRILL_S3': 'true' if s3 else 'false'}
os.umask(0o077)


def command(args, database, stage=None):
    result = subprocess.run(args, cwd=ROOT, env={**env, 'PGDATABASE': database},
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        # Child exception data can contain synthetic credentials. Report only stage.
        raise RuntimeError(f'Restore drill command failed: {stage or args[0]}')


try:
    for name in names:
        command(['createdb', '--no-password', '--template=template0', name], 'postgres')
        created.append(name)
    source, target = names
    with tempfile.TemporaryDirectory(prefix='atoll-schema-drill-') as temporary:
        evidence = str(Path(temporary) / 'evidence.json')
        archive = str(Path(temporary) / 'archive')
        fixture = ['mix', 'run', '--no-start', 'scripts/database_restore_fixture.exs']
        command(fixture + ['seed', evidence], source, 'seed Atoll schema and data')
        backup = [sys.executable, 'scripts/database_backup.py']
        command(backup + ['backup', archive], source, 'archive source database')
        if s3:
            blobs = str(Path(temporary) / 'blobs')
            command(fixture + ['backup_s3', blobs], source, 'archive source S3 bytes')
        command(backup + ['restore', archive], target, 'restore target database')
        if s3:
            command(fixture + ['missing_s3', evidence], target, 'reject missing target S3 bytes')
            command(fixture + ['restore_s3', blobs], target, 'restore target S3 bytes')
        command(fixture + ['verify', evidence], target, 'verify restored Atoll data')
    print('Atoll schema and data restore drill passed (' + ('S3' if s3 else 'PostgreSQL blobs') + ')')
finally:
    for name in reversed(created):
        command(['dropdb', '--no-password', name], 'postgres')
