#!/usr/bin/env python3
"""Recovery-set pairing and mutation-order tests; real stores use the Atoll drill."""
import os
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import recovery_set as recovery


class RecoverySetTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name) / 'set'
        self.calls = []
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, {'PGDATABASE': 'atoll_backup_test'}).start()
        patch.object(recovery.database, 'backup', self.database_backup).start()
        patch.object(recovery.database, 'verify', lambda p: self.calls.append('verify database')).start()
        patch.object(recovery.database, 'require_empty_target', lambda: self.calls.append('empty database')).start()
        patch.object(recovery.database, 'restore', lambda p: self.calls.append('restore database')).start()
        patch.object(recovery, 's3', self.s3).start()

    def database_backup(self, path):
        path.mkdir()
        (path / 'manifest.json').write_text('{"database":"fixture"}')

    def s3(self, action, path):
        self.calls.append(action + ' s3')
        if action == 'backup':
            path.mkdir()
            (path / 'manifest.json').write_text('{"s3":"fixture"}')

    def backup(self, storage='s3'):
        recovery.backup(self.directory, storage, 'a' * 40, 'offline-keyring-1')
        self.calls.clear()

    def test_restore_verifies_both_components_before_mutation(self):
        self.backup()
        recovery.restore(self.directory)
        self.assertEqual(self.calls, ['verify database', 'verify s3', 'empty database',
                                      'restore s3', 'restore database'])

    def test_component_swap_fails_before_any_target_or_archive_tool(self):
        for component in ['database', 's3']:
            with self.subTest(component=component):
                if not self.directory.exists():
                    self.backup()
                path = self.directory / component / 'manifest.json'
                original = path.read_text()
                path.write_text('{}')
                with self.assertRaises(recovery.database.BackupError):
                    recovery.restore(self.directory)
                self.assertEqual(self.calls, [])
                path.write_text(original)

    def test_populated_database_prevents_s3_mutation(self):
        self.backup()
        with patch.object(recovery.database, 'require_empty_target',
                          side_effect=recovery.database.BackupError('not empty')):
            with self.assertRaises(recovery.database.BackupError):
                recovery.restore(self.directory)
        self.assertEqual(self.calls, ['verify database', 'verify s3'])

    def test_s3_failure_prevents_database_restore(self):
        self.backup()
        def fail_restore(action, path):
            if action == 'restore':
                raise recovery.database.BackupError('S3 failure')
        with patch.object(recovery, 's3', fail_restore):
            with self.assertRaises(recovery.database.BackupError):
                recovery.restore(self.directory)
        self.assertNotIn('restore database', self.calls)

    def test_failed_backup_removes_only_new_directory(self):
        with patch.object(recovery, 's3', side_effect=recovery.database.BackupError('failure')):
            with self.assertRaises(recovery.database.BackupError):
                self.backup()
        self.assertFalse(self.directory.exists())
        self.backup()
        original = (self.directory / 'recovery.json').read_bytes()
        with self.assertRaises(FileExistsError):
            self.backup()
        self.assertEqual((self.directory / 'recovery.json').read_bytes(), original)

    def test_postgres_set_never_contacts_s3(self):
        self.backup('postgres')
        recovery.restore(self.directory)
        self.assertEqual(self.calls, ['verify database', 'empty database', 'restore database'])
        (self.directory / 's3').mkdir()
        with self.assertRaises(recovery.database.BackupError):
            recovery.verify(self.directory)

    def test_symlink_components_and_manifest_are_rejected(self):
        self.backup()
        for name in ['database', 's3', 'recovery.json']:
            original = self.directory / name
            moved = self.directory / (name + '.original')
            original.rename(moved)
            original.symlink_to(moved)
            with self.assertRaises(recovery.database.BackupError):
                recovery.verify(self.directory)
            original.unlink()
            moved.rename(original)
        self.assertEqual(self.calls, [])

    def test_missing_revision_or_reference_rejected_before_backup(self):
        for revision, reference in [('', 'keys'), ('a' * 40, ''), ('main', 'keys')]:
            with self.assertRaises(recovery.database.BackupError):
                recovery.backup(self.directory, 's3', revision, reference)
        self.assertFalse(self.directory.exists())

    def test_cli_refuses_mutation_without_offline_acknowledgment(self):
        for action in ['backup', 'restore']:
            with patch('sys.argv', ['recovery_set.py', action, str(self.directory)]):
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as error:
                        recovery.main()
            self.assertEqual(error.exception.code, 2)
        self.assertFalse(self.directory.exists())
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
