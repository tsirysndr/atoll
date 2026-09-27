#!/usr/bin/env python3
"""Logical database archives using PostgreSQL client tools and libpq environment."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


class BackupError(Exception):
    pass


def run(program, *args, capture=False):
    try:
        return subprocess.run(
            [program, *args], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.PIPE, check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        # libpq errors can include connection details; never echo credentials.
        raise BackupError(f"{program} failed; check connectivity, privileges and client/server versions") from None


def database():
    name = os.environ.get("PGDATABASE", "")
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,62}", name):
        raise BackupError("Set PGDATABASE to an explicit plain database name (not a connection URI)")
    return name


def digest(path):
    sha = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            sha.update(chunk)
            size += len(chunk)
    return sha.hexdigest(), size


def verify(directory):
    manifest = directory / "manifest.json"
    archive = directory / "database.dump"
    if (not manifest.is_file() or manifest.is_symlink() or manifest.stat().st_size > 65536
            or not archive.is_file() or archive.is_symlink()):
        raise BackupError("Missing or invalid backup files")
    try:
        data = json.loads(manifest.read_text())
    except (ValueError, UnicodeError):
        raise BackupError("Invalid backup manifest") from None
    if not isinstance(data, dict) or data.get("format") != "atoll-postgres-v1":
        raise BackupError("Unsupported backup manifest")
    checksum, size = digest(archive)
    if size == 0 or data.get("sha256") != checksum or data.get("bytes") != size:
        raise BackupError("Archive checksum or size mismatch")
    run("pg_restore", "--list", str(archive))
    return archive


def backup(directory):
    database()
    # Never overwrite an existing backup, including an incomplete one.
    directory.mkdir(mode=0o700)
    complete = False
    try:
        version = run("pg_dump", "--version", capture=True).decode().strip()
        archive = directory / "database.dump"
        run("pg_dump", "--no-password", "--dbname", database(), "--format=custom", "--file", str(archive))
        archive.chmod(0o600)
        checksum, size = digest(archive)
        manifest = {
            "format": "atoll-postgres-v1", "sha256": checksum, "bytes": size,
            "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "pgDumpVersion": version,
        }
        (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        verify(directory)
        complete = True
    finally:
        if not complete:
            shutil.rmtree(directory)


def restore(directory):
    database()
    archive = verify(directory)
    # Also reject non-table objects and additional empty schemas. The target must
    # be a fresh template0 database, with no application connected to it.
    sql = """
    SELECT EXISTS (
      SELECT 1 FROM pg_namespace WHERE nspname NOT IN ('public', 'information_schema')
        AND nspname NOT LIKE 'pg_%'
      UNION ALL
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
      UNION ALL
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
      UNION ALL
      SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public'
      UNION ALL
      SELECT 1 FROM pg_extension WHERE extname <> 'plpgsql'
    )
    """
    result = run("psql", "--no-password", "--dbname", database(), "-XAt", "--set=ON_ERROR_STOP=1", "-c", sql, capture=True)
    if result.strip() != b"f":
        raise BackupError("Restore target is not empty; create a dedicated database from template0")
    run("pg_restore", "--no-password", "--exit-on-error", "--single-transaction",
        "--no-owner", "--no-privileges", "--dbname", database(), str(archive))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["backup", "verify", "restore"])
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        {"backup": backup, "verify": verify, "restore": restore}[args.action](args.directory.resolve())
    except (BackupError, OSError) as error:
        # OSError text can reveal paths but not libpq connection credentials.
        print(f"Database {args.action} failed: {error}", file=sys.stderr)
        return 1
    print(f"Database {args.action} completed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
