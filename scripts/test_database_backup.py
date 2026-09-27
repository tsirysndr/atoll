#!/usr/bin/env python3
"""Exercise archive/restore on disposable PostgreSQL databases; needs CREATEDB."""
import hashlib
import json
import shutil
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
NAMES = ['atoll_backup_test_' + uuid.uuid4().hex for _ in range(2)]
created = []


def command(args, db, ok=True):
    env = {**os.environ, 'PGDATABASE': db}
    result = subprocess.run(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert (result.returncode == 0) == ok, f"Unexpected status for {args[0]}: {result.returncode}"
    return result.stdout


def sql(db, query):
    return command(['psql', '--dbname', db, '-XAt', '--no-password', '--set=ON_ERROR_STOP=1', '-c', query], db).strip()


try:
    for name in NAMES:
        command(['createdb', '--no-password', '--template=template0', name], 'postgres')
        created.append(name)
    source, target = NAMES
    sql(source, "CREATE TABLE fixture (id bigserial PRIMARY KEY, data bytea NOT NULL); INSERT INTO fixture(data) VALUES (decode('0001ff', 'hex')); CREATE INDEX fixture_data ON fixture(data);")
    with tempfile.TemporaryDirectory(prefix='atoll-backup-test-') as temporary:
        archive = Path(temporary) / 'archive'
        script = [sys.executable, str(ROOT / 'scripts/database_backup.py')]
        failed = Path(temporary) / 'failed'
        command(script + ['backup', str(failed)], source + '_missing', ok=False)
        assert not failed.exists()
        command(script + ['backup', str(archive)], source)
        assert archive.stat().st_mode & 0o777 == 0o700
        for file in archive.iterdir():
            assert file.stat().st_mode & 0o777 == 0o600
        command(script + ['backup', str(archive)], source, ok=False)
        command(script + ['verify', str(archive)], target)
        dump = archive / 'database.dump'
        original_size = dump.stat().st_size
        with dump.open('ab') as stream:
            stream.write(b'tampered')
        command(script + ['restore', str(archive)], target, ok=False)
        assert sql(target, "SELECT count(*) FROM pg_tables WHERE schemaname='public'") == b'0'
        with dump.open('r+b') as stream:
            stream.truncate(original_size)
        # A readable TOC with truncated data must fail inside pg_restore and
        # roll back even the schema created before that data failure.
        broken = Path(temporary) / 'broken'
        shutil.copytree(archive, broken)
        broken_dump = broken / 'database.dump'
        with broken_dump.open('r+b') as stream:
            stream.truncate(original_size - 16)
        manifest = json.loads((broken / 'manifest.json').read_text())
        manifest.update(bytes=broken_dump.stat().st_size,
                        sha256=hashlib.sha256(broken_dump.read_bytes()).hexdigest())
        (broken / 'manifest.json').write_text(json.dumps(manifest))
        command(script + ['verify', str(broken)], target)
        command(script + ['restore', str(broken)], target, ok=False)
        assert sql(target, "SELECT count(*) FROM pg_tables WHERE schemaname='public'") == b'0'
        sql(target, 'CREATE SCHEMA unexpected')
        command(script + ['restore', str(archive)], target, ok=False)
        sql(target, 'DROP SCHEMA unexpected')
        command(script + ['restore', str(archive)], target)
        assert sql(target, "SELECT id, encode(data, 'hex') FROM fixture") == b'1|0001ff'
        assert sql(target, "INSERT INTO fixture(data) VALUES (decode('abcd','hex')) RETURNING id") == b'2\nINSERT 0 1'
        assert sql(target, "SELECT count(*) FROM pg_indexes WHERE tablename='fixture'") == b'2'
        command(script + ['restore', str(archive)], target, ok=False)
        assert sql(target, 'SELECT count(*) FROM fixture') == b'2'
    print('Database backup/restore integration passed')
finally:
    for name in reversed(created):
        command(['dropdb', '--no-password', name], 'postgres')
