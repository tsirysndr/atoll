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


def command(args, database, stage=None, ok=True, expected_error=None):
    command_env = {**env, 'PGDATABASE': database}
    if s3:
        command_env.update({
            'ATOLL_S3_ENDPOINT': env['ATOLL_MINIO_TEST_ENDPOINT'],
            'ATOLL_S3_BUCKET': database.replace('atoll_backup_test_', 'atoll-backup-', 1),
            'ATOLL_S3_ACCESS_KEY_ID': 'atoll-test',
            'ATOLL_S3_SECRET_ACCESS_KEY': 'atoll-minio-test-only',
            'ATOLL_S3_REGION': 'us-east-1',
        })
        command_env.pop('ATOLL_S3_SESSION_TOKEN', None)
    result = subprocess.run(args, cwd=ROOT, env=command_env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if (result.returncode == 0) != ok:
        # Child exception data can contain synthetic credentials. Report only stage.
        raise RuntimeError(f'Restore drill command failed: {stage or args[0]}')
    if expected_error and expected_error.encode() not in result.stderr:
        raise RuntimeError(f'Restore drill rejected for an unexpected reason: {stage}')


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
        recovery = [sys.executable, 'scripts/recovery_set.py']
        revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        metadata = ['--revision', revision, '--keyring-reference', 'ephemeral-drill-keys']
        if s3:
            command(recovery + ['backup', archive, '--offline', '--storage', 'postgres'] + metadata,
                    source, 'refuse a PostgreSQL-only set with S3 ownership', ok=False,
                    expected_error='Database owns S3 blobs')
            assert not Path(archive).exists()
            command(fixture + ['remove_source_blob', evidence], source, 'remove disposable source blob')
            command(recovery + ['backup', archive, '--offline', '--storage', 's3'] + metadata,
                    source, 'refuse a recovery set missing an owned S3 blob', ok=False,
                    expected_error='missing a database-owned S3 blob')
            assert not Path(archive).exists()
            command(fixture + ['repair_source_blob', evidence], source, 'repair disposable source blob')
        command(recovery + ['backup', archive, '--offline', '--storage', 's3' if s3 else 'postgres',
                            '--revision', revision, '--keyring-reference', 'ephemeral-drill-keys'],
                source, 'create paired recovery set')
        assert Path(archive).stat().st_mode & 0o777 == 0o700
        assert (Path(archive) / 'recovery.json').stat().st_mode & 0o777 == 0o600
        command(recovery + ['verify', archive], source, 'verify paired recovery set')
        if s3:
            # Demonstrate that restoring only metadata cannot serve source bytes.
            command([sys.executable, 'scripts/database_backup.py', 'restore',
                     str(Path(archive) / 'database')], target, 'restore metadata alone')
            command(fixture + ['missing_s3', evidence], target, 'reject missing target S3 bytes')
            # Return to a fresh target before exercising the complete wrapper.
            command(['dropdb', '--no-password', target], 'postgres')
            created.remove(target)
            command(['createdb', '--no-password', '--template=template0', target], 'postgres')
            created.append(target)
        command(recovery + ['restore', archive, '--offline'], target, 'restore paired recovery set')
        command(fixture + ['verify', evidence], target, 'verify restored Atoll data')
    print('Atoll schema and data restore drill passed (' + ('S3' if s3 else 'PostgreSQL blobs') + ')')
finally:
    for name in reversed(created):
        command(['dropdb', '--no-password', name], 'postgres')
