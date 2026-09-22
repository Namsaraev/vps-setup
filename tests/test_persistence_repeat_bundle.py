"""Persistence bundle: real writer, injected I/O faults, temporary files only.

The POSIX tests require Linux; pure transform tests also run on Windows.
No daemon, firewall, package, kernel or swap operations are executed here.
"""
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from atomic_support import PROGRAM, WRAPPER
import test_swap_persistence as swap
import test_ssh_error_contract as ssh
import test_configure_unattended_upgrades as unattended
import test_configure_autoremove as autoremove
import test_configure_safe_sysctl as sysctl
import test_configure_systemd_limits as limits
import test_configure_shell as shell

NAMESPACE = {}
exec(PROGRAM.split('\ntry:\n    persist(sys.argv', 1)[0], NAMESPACE)
transform = NAMESPACE['transform']
TARGETS = [
    ('etc/fstab', 'fstab', ['/swapfile'], b'# keep\n/swapfile none swap defaults 0 0\n',
     b'# keep\n/swapfile none swap sw 0 0\n'),
    ('etc/ssh/sshd_config', 'sshd', ['Port', '5829'], b'#Port 22\n# keep\n', b'Port 5829\n# keep\n'),
    ('etc/ssh/sshd_config.d/00-vps-hardening.conf', 'text', [], b'# old policy\n', b'PasswordAuthentication no\n'),
    ('etc/systemd/system/ssh.socket.d/99-vps-port.conf', 'text', [], b'[Socket]\nListenStream=22\n', b'[Socket]\nListenStream=\nListenStream=5829\n'),
] + [(path, 'text', [], b'# previous config\n', b'# complete generated config\n') for path in (
    'etc/apt/apt.conf.d/20auto-upgrades', 'etc/apt/apt.conf.d/50auto-remove',
    'etc/modules-load.d/tcp_bbr.conf', 'etc/sysctl.d/99-vps-tuning.conf',
    'etc/security/limits.d/99-vps.conf', 'etc/systemd/system.conf.d/99-nofile.conf',
    'home/.config/tunevps/zshrc',
)] + [('home/.zshrc', 'zshrc', [], b'# user\r\nlast\xff', shell.BLOCK + b'# user\r\nlast\xff')]


class TransformTest(unittest.TestCase):
    def test_fstab_preserves_unrelated_bytes_and_normalizes_only_managed_swap(self):
        untouched = (b'# /swapfile none swap defaults 0 0\r\n/dev/zram0 none swap sw 0 0\n'
                     b'/swapfile.backup none swap sw 0 0\n/swapfile /mnt ext4 defaults 0 0\n')
        original = untouched + b'  /swapfile ignored swap defaults 3 8\n/swapfile none swap sw 0 0\n'
        expected = untouched + b'/swapfile none swap sw 0 0\n'
        self.assertEqual(transform(original, 'fstab', ['/swapfile']), expected)
        self.assertEqual(transform(expected, 'fstab', ['/swapfile']), expected)

    def test_fstab_missing_final_newline_is_separated(self):
        for tail in (b'# tail', b'/dev/root / ext4 defaults 0 1', b''):
            expected = tail + (b'\n' if tail else b'') + b'/swapfile none swap sw 0 0\n'
            self.assertEqual(transform(tail, 'fstab', ['/swapfile']), expected)

    def test_correct_fstab_row_keeps_position_and_all_bytes(self):
        before = b'# first\n/swapfile none swap sw 0 0\n# final no newline'
        self.assertEqual(transform(before, 'fstab', ['/swapfile']), before)

    def test_sshd_preserves_existing_edit_contract_and_comment_bytes(self):
        for before, after in ((b'#Port 22\nPort 23\n# keep\xff', b'Port 5829\nPort 5829\n# keep\xff'),
                              (b'# tail', b'# tail\nPort 5829\n')):
            self.assertEqual(transform(before, 'sshd', ['Port', '5829']), after)
            self.assertEqual(transform(after, 'sshd', ['Port', '5829']), after)

    def test_zshrc_preserves_bytes_and_rejects_bad_markers(self):
        user = b'alias mine=yes\r\n# \xff'
        self.assertEqual(transform(user, 'zshrc', []), shell.BLOCK + user)
        self.assertEqual(transform(shell.BLOCK + user, 'zshrc', []), shell.BLOCK + user)
        with self.assertRaisesRegex(ValueError, 'Invalid or duplicate'):
            transform(shell.BLOCK * 2, 'zshrc', [])


@unittest.skipUnless(os.name == 'posix', 'Real dir_fd/O_NOFOLLOW/ownership require POSIX; verified on Linux')
class AtomicFilesTest(unittest.TestCase):
    def invoke(self, path, kind, args=(), data=b'', failure=''):
        return subprocess.run([sys.executable, str(WRAPPER), '-c', PROGRAM, str(path), kind, *args],
                              input=data, capture_output=True, timeout=10,
                              env={**os.environ, 'ATOMIC_FAILURE': failure, 'ATOMIC_TARGET': ''})

    def failures(self, failure, committed=False):
        for relative, kind, args, before, expected in TARGETS:
            with self.subTest(target=relative, failure=failure), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp, relative)
                path.parent.mkdir(parents=True)
                path.write_bytes(before)
                path.chmod(0o640)
                initial = path.stat()
                result = self.invoke(path, kind, args, expected, failure)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertIn(b'Atomic configuration update failed', result.stderr)
                self.assertEqual(path.read_bytes(), expected if committed else before)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
                self.assertEqual((path.stat().st_uid, path.stat().st_gid), (initial.st_uid, initial.st_gid))
                if not committed:
                    self.assertEqual(path.stat().st_ino, initial.st_ino)
                    self.assertEqual(path.stat().st_mtime_ns, initial.st_mtime_ns)
                if failure == 'cleanup':
                    self.assertEqual(len(list(path.parent.glob('.tunevps-*'))), 1)
                else:
                    self.assertEqual(list(path.parent.glob('.tunevps-*')), [])

    def test_success_and_repeat_preserve_metadata_and_inode_on_noop(self):
        for relative, kind, args, before, expected in TARGETS:
            with self.subTest(target=relative), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp, relative)
                path.parent.mkdir(parents=True)
                path.write_bytes(before)
                path.chmod(0o640)
                initial = path.stat()
                result = self.invoke(path, kind, args, expected)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(path.read_bytes(), expected)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
                self.assertEqual((path.stat().st_uid, path.stat().st_gid), (initial.st_uid, initial.st_gid))
                first = path.stat()
                result = self.invoke(path, kind, args, expected, 'temp_open')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((path.stat().st_ino, path.stat().st_mtime_ns), (first.st_ino, first.st_mtime_ns))

    def test_missing_required_sources_fail_and_generated_files_can_be_created(self):
        with tempfile.TemporaryDirectory() as tmp:
            for kind, args in (('fstab', ['/swapfile']), ('sshd', ['Port', '5829'])):
                path = Path(tmp, kind)
                self.assertNotEqual(self.invoke(path, kind, args).returncode, 0)
                self.assertFalse(path.exists())
            for kind in ('text', 'zshrc'):
                path = Path(tmp, kind)
                result = self.invoke(path, kind, data=b'new\n')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)
                self.assertEqual(path.stat().st_uid, os.getuid())

    def test_symlink_directory_fifo_and_symlink_parent_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            victim = root / 'victim'
            victim.write_bytes(b'preserved')
            (root / 'link').symlink_to(victim)
            (root / 'directory').mkdir()
            os.mkfifo(root / 'fifo')
            (root / 'parent-link').symlink_to(root / 'directory', target_is_directory=True)
            for target in (root / 'link', root / 'directory', root / 'fifo', root / 'parent-link/config'):
                result = self.invoke(target, 'text', data=b'replacement')
                self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertEqual(victim.read_bytes(), b'preserved')
            self.assertEqual(list((root / 'directory').iterdir()), [])

    def test_source_replaced_by_symlink_during_open_is_not_followed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path, victim = Path(tmp, 'config'), Path(tmp, 'victim')
            path.write_bytes(b'old')
            victim.write_bytes(b'do not touch')
            opened = os.open

            def race(name, *args, **kwargs):
                if name == 'config':
                    path.unlink()
                    path.symlink_to(victim)
                return opened(name, *args, **kwargs)

            with patch.object(os, 'open', race), self.assertRaises(OSError):
                NAMESPACE['persist'](str(path), 'sshd', ['Port', '5829'])
            self.assertEqual(victim.read_bytes(), b'do not touch')
            self.assertTrue(path.is_symlink())

    def test_parent_substitution_cannot_redirect_temp_or_replacement(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            parent, moved, alternate = root / 'parent', root / 'moved', root / 'alternate'
            parent.mkdir()
            alternate.mkdir()
            (parent / 'config').write_bytes(b'# original')
            (alternate / 'config').write_bytes(b'# other')
            opened = os.open

            def race(name, flags, *args, **kwargs):
                if flags & os.O_CREAT:
                    parent.rename(moved)
                    parent.symlink_to(alternate, target_is_directory=True)
                return opened(name, flags, *args, **kwargs)

            with patch.object(os, 'open', race), self.assertRaises(OSError):
                NAMESPACE['persist'](str(parent / 'config'), 'sshd', ['Port', '5829'])
            self.assertEqual((moved / 'config').read_bytes(), b'# original')
            self.assertEqual((alternate / 'config').read_bytes(), b'# other')
            self.assertEqual(list(moved.glob('.tunevps-*')), [])

    def test_concurrent_source_change_detected_before_replace(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, 'config')
            path.write_bytes(b'# original')
            synced = os.fsync

            def race(descriptor):
                path.write_bytes(b'# concurrent update')
                return synced(descriptor)

            with patch.object(os, 'fsync', race), self.assertRaises(OSError):
                NAMESPACE['persist'](str(path), 'sshd', ['Port', '5829'])
            self.assertEqual(path.read_bytes(), b'# concurrent update')
            self.assertEqual(list(path.parent.glob('.tunevps-*')), [])


for _failure in ('source_open', 'read', 'short_read', 'temp_open', 'write', 'short_write',
                 'flush', 'fsync', 'chown', 'chmod', 'stage_read', 'replace', 'cleanup',
                 'dir_fsync', 'post_read'):
    def _test(self, failure=_failure):
        self.failures(failure, committed=failure in ('dir_fsync', 'post_read'))
    setattr(AtomicFilesTest, 'test_failure_' + _failure, _test)


@unittest.skipUnless(os.name == 'posix', 'Real persistence integration verified on Linux')
class PersistenceIntegrationTest(unittest.TestCase):
    def test_ssh_special_source_is_rejected_before_backup(self):
        for create in ('command mkdir "$ROOT/etc/ssh/sshd_config"',
                       'command mkfifo "$ROOT/etc/ssh/sshd_config"',
                       'command ln -s "$ROOT/etc/ssh/saved" "$ROOT/etc/ssh/sshd_config"'):
            setup = 'command mv "$ROOT/etc/ssh/sshd_config" "$ROOT/etc/ssh/saved"\n' + create
            with self.subTest(create=create):
                result, calls, _ = ssh.SshErrorContractTest().run_ssh(extra_setup=setup, outer=True)
                ssh.SshErrorContractTest().assert_failed(result, calls)
                self.assertNotIn('cp\n', calls)

    def test_active_swap_repairs_missing_and_duplicate_rows_without_runtime_mutations(self):
        for before in (swap.FSTAB, swap.FSTAB + '/swapfile ignored swap defaults 0 1\n' * 2):
            result, calls, after, active = swap.SwapPersistenceTest().run_swap(
                active='/swapfile 2147479552 file\n', fstab=before, repeat=True, outer=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls, '')
            self.assertEqual(after, swap.FSTAB + '/swapfile none swap sw 0 0\n')
            self.assertEqual(active, '/swapfile 2147479552 file\n')

    def test_swap_active_repair_and_creation_failures_stop_real_part2(self):
        for active in ('', '/swapfile 2147479552 file\n'):
            for failure in ('read', 'source_open', 'temp_open', 'write', 'short_write', 'flush',
                            'fsync', 'chown', 'chmod', 'replace', 'cleanup', 'dir_fsync', 'post_read'):
                with self.subTest(active=active, failure=failure), patch.dict(os.environ, ATOMIC_FAILURE=failure):
                    result, calls, after, _ = swap.SwapPersistenceTest().run_swap(active=active, outer=True)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertNotIn('OK:', result.stdout)
                    self.assertNotIn('Часть 2 завершена', result.stdout)
                    self.assertIn('не подтверждено', result.stderr)
                    if active:
                        self.assertEqual(calls, '')
                    if failure not in ('dir_fsync', 'post_read'):
                        self.assertEqual(after, swap.FSTAB)

    def test_ssh_each_persistence_target_failure_stops_restart_and_part2(self):
        for target in ('/sshd_config', '/00-vps-hardening.conf', '/99-vps-port.conf'):
            for failure in ('source_open', 'read', 'short_read', 'temp_open', 'write', 'short_write',
                            'flush', 'fsync', 'chown', 'chmod', 'stage_read', 'replace', 'cleanup',
                            'dir_fsync', 'post_read'):
                with self.subTest(target=target, failure=failure), patch.dict(
                        os.environ, ATOMIC_FAILURE=failure, ATOMIC_TARGET=target):
                    result, calls, config, files = ssh.SshErrorContractTest().run_ssh(
                        outer=True, existing_targets=True, snapshots=True)
                    ssh.SshErrorContractTest().assert_failed(result, calls)
                    self.assertIn('Atomic configuration update failed', result.stderr)
                    if failure not in ('dir_fsync', 'post_read'):
                        if target == '/sshd_config':
                            self.assertEqual(config, '#Port 22\n')
                        else:
                            path = ssh.HARDENING if target.endswith('hardening.conf') else ssh.SOCKET
                            self.assertEqual(files[path], b'# previous live config\n')

    def test_other_callers_stop_on_persistence_failure(self):
        cases = (
            ('/20auto-upgrades', lambda: unattended.ConfigureUnattendedUpgradesTest().run_setup(part2=True)[0]),
            ('/50auto-remove', lambda: autoremove.ConfigureAutoremoveTest().run_setup(part2=True)[0]),
            ('/tcp_bbr.conf', lambda: sysctl.ConfigureSafeSysctlTest().run_setup(part2=True)[0]),
            ('/99-vps-tuning.conf', lambda: sysctl.ConfigureSafeSysctlTest().run_setup(part2=True)[0]),
            ('/99-vps.conf', lambda: sysctl.ConfigureSafeSysctlTest().run_setup(part2=True)[0]),
            ('/99-nofile.conf', lambda: limits.ConfigureSystemdLimitsTest().run_setup(part2=True)[0]),
        )
        for target, run in cases:
            for failure in ('temp_open', 'short_write', 'fsync', 'chmod', 'replace', 'cleanup'):
                with self.subTest(target=target, failure=failure), patch.dict(
                        os.environ, ATOMIC_FAILURE=failure, ATOMIC_TARGET=target):
                    result = run()
                    self.assertNotEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn('Часть 2 завершена', result.stdout)

    def test_both_shell_targets_preserve_old_bytes_on_failure_and_stop_part2(self):
        for target in ('/zshrc', '/.zshrc'):
            for failure in ('source_open', 'read', 'temp_open', 'write', 'short_write', 'flush',
                            'fsync', 'chown', 'chmod', 'replace', 'cleanup'):
                with self.subTest(target=target, failure=failure), patch.dict(
                        os.environ, ATOMIC_FAILURE=failure, ATOMIC_TARGET=target):
                    fixture = shell.ConfigureShellTest()
                    fixture.setUp()
                    try:
                        fixture.managed.parent.mkdir(parents=True)
                        fixture.managed.write_bytes(b'# old generated config\n')
                        fixture.rc.write_bytes(b'# user config\xff')
                        result = fixture.run_shell(success=False, part2=True)
                        self.assertIn('Atomic configuration update failed', result.stderr)
                        self.assertEqual(fixture.rc.read_bytes(), b'# user config\xff')
                        if target == '/zshrc':
                            self.assertEqual(fixture.managed.read_bytes(), b'# old generated config\n')
                    finally:
                        fixture.doCleanups()


if __name__ == '__main__':
    unittest.main()
