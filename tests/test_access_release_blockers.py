"""Access safety helpers with temporary paths and evidence, no host mutations."""
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from access_support import PROGRAM


def run(op, *args, data='', program=PROGRAM):
    return subprocess.run([sys.executable, '-c', program, op, *map(str, args)],
                          input=data, text=True, capture_output=True, timeout=10)


SOCKET = ('LoadState=loaded\nActiveState=active\nUnitFileState=enabled\n'
          'NeedDaemonReload=no\nDropInPaths=\n'
          'Accept=no\nTriggers=ssh.service\nListen=0.0.0.0:22 (Stream)\nListen=[::]:22 (Stream)\n')
SERVICE = ('LoadState=loaded\nActiveState=active\nMainPID=42\n'
           'ExecStart={ path=/usr/sbin/sshd ; argv[]=/usr/sbin/sshd -D ; }\n')


class AccessEvidenceTest(unittest.TestCase):
    def test_context_trace_fail_closed(self):
        trace = ('debug1: sshd version OpenSSH_9.6, OpenSSL fixture\n'
                 'debug2: parse_server_config_depth: fixture\n'
                 'authorizedkeysfile .ssh/authorized_keys\n'
                 'pubkeyauthentication yes\nauthenticationmethods any\n')
        for expression, expected in [('User pin', 0), ('Group admins', 0), ('all', 0),
                                     ('Address 192.0.2.0/24', 2), ('Host *.example', 2),
                                     ('LocalPort 22', 2), ('LocalAddress 192.0.2.1', 2)]:
            data = trace + "debug3: checking syntax for 'Match " + expression + "'\n"
            r = run('effective', '/srv/pin', 'pin', 'checked-context', data=data)
            self.assertEqual(r.returncode, expected, r.stderr)
        for data in (trace.replace('9.6', '10.0'), trace.replace('pubkeyauthentication yes', 'pubkeyauthentication no'),
                     trace.replace('authenticationmethods any', 'authenticationmethods publickey,password'), ''):
            self.assertNotEqual(run('effective', '/srv/pin', 'pin', 'checked-context', data=data).returncode, 0)

    def test_effective_key_path(self):
        for path in ('.ssh/authorized_keys', '%h/.ssh/authorized_keys', '/srv/pin/.ssh/authorized_keys',
                     '/srv/%u/.ssh/authorized_keys', '.ssh/other .ssh/authorized_keys'):
            with self.subTest(path=path):
                r = run('effective', '/srv/pin', 'pin', data='authorizedkeysfile ' + path + '\n')
                self.assertEqual(r.returncode, 0, r.stderr)

    def test_effective_path_fail_closed(self):
        for text in ('', 'authorizedkeysfile\n', 'authorizedkeysfile none\n',
                     'authorizedkeysfile .ssh/custom\n',
                     'authorizedkeysfile %x/.ssh/authorized_keys\n',
                     'authorizedkeysfile .ssh/authorized_keys\nauthorizedkeysfile .ssh/authorized_keys\n'):
            self.assertNotEqual(run('effective', '/srv/pin', 'pin', data=text).returncode, 0)

    def test_bind_addresses_preserved(self):
        for old in (SOCKET, SOCKET.replace('0.0.0.0', '192.0.2.5').replace('[::]', '[2001:db8::5]')):
            r = run('socket', 5829, data=old)
            self.assertEqual(r.returncode, 0, r.stderr)
            for line in old.splitlines():
                if line.startswith('Listen='):
                    self.assertIn('ListenStream=' + line[7:].replace(':22 (Stream)', ':5829'), r.stdout)

    def test_service_does_not_generate_override(self):
        r = run('socket', 5829, data='LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, 'service\n')

    def test_unsupported_bind_policy(self):
        for state in ('', SOCKET.replace('[::]:22', '[::]:23'),
                      SOCKET.replace('0.0.0.0:22', '/run/ssh.sock'), SOCKET.replace('Accept=no', 'Accept=yes'),
                      SOCKET.replace('Triggers=ssh.service', 'Triggers=other.service'),
                      SOCKET.replace('NeedDaemonReload=no', 'NeedDaemonReload=yes'),
                      SOCKET.replace('DropInPaths=', 'DropInPaths=/etc/systemd/system/ssh.socket.d/zz-local.conf')):
            self.assertNotEqual(run('socket', 5829, data=state).returncode, 0)

    def test_listener_identity_service_socket_foreign_absent_failure(self):
        socket = SOCKET.replace(':22', ':5829')
        for row, expected in [('', 1), ('LISTEN 0 128 0.0.0.0:5829 *:* users:(("sshd",pid=42,fd=3))', 0),
                              ('LISTEN 0 128 0.0.0.0:5829 *:* users:(("systemd",pid=1,fd=3))', 0),
                              ('LISTEN 0 128 0.0.0.0:5829 *:* users:(("sshd",pid=99,fd=3))', 4),
                              ('LISTEN 0 128 0.0.0.0:5829 *:*', 2)]:
            r = run('listener', 5829, SERVICE, socket, data=row)
            self.assertEqual(r.returncode, expected, r.stderr)
        self.assertEqual(run('listener', 5829, '', socket, data='LISTEN 0 128 0.0.0.0:5829 *:*').returncode, 2)

    def test_ufw_precedence(self):
        cases = [('', 1), ('[ 1] 5829/tcp  ALLOW IN  Anywhere', 0),
                 ('[ 1] 5829/tcp  DENY IN  Anywhere\n[ 2] 5829/tcp  ALLOW IN  Anywhere', 2),
                 ('[ 1] 5829/tcp  REJECT IN  192.0.2.1\n[ 2] 5829/tcp  ALLOW IN  Anywhere', 2),
                 ('[ 1] 80/tcp  DENY IN  Anywhere\n[ 2] 5829/tcp  ALLOW IN  Anywhere', 0),
                 ('[ 1] 5829/tcp  ALLOW IN  Anywhere\n[ 2] Anywhere  DENY IN  Anywhere', 0),
                 ('[ 1] 5800:5900/tcp  DENY IN  Anywhere', 2),
                 ('[ 1] 5829/tcp  ALLOW IN  192.0.2.1', 1),
                 ('[ 1] 5829/tcp  ALLOW IN  Anywhere\n[ 2] 5829/tcp (v6)  DENY IN  Anywhere (v6)', 2)]
        for rules, expected in cases:
            self.assertEqual(run('ufw', 5829, data='Status: active\n' + rules).returncode, expected, rules)
        self.assertEqual(run('ufw', 5829, data='garbage').returncode, 2)


class AccessOrchestrationTest(unittest.TestCase):
    def test_effective_match_failure_before_apply_and_fast_path(self):
        from test_ssh_error_contract import SshErrorContractTest
        for applied in (False, True):
            for outcome in ("echo 'authorizedkeysfile .ssh/elsewhere'", 'return 23', 'echo empty'):
                setup = ('touch "$ROOT/applied"\n' if applied else '') + '''
eval "$(declare -f sshd | command sed '1s/sshd/original_sshd/')"
sshd() { if [[ "$*" == *' -C '* ]]; then ''' + outcome + '''; else original_sshd "$@"; fi; }
'''
                r, calls, main = SshErrorContractTest().run_ssh(extra_setup=setup)
                self.assertNotEqual(r.returncode, 0)
                self.assertNotIn('preflight', calls)
                self.assertNotIn('systemctl restart', calls)
                self.assertEqual(main, '#Port 22\n')

    def test_aggregate_failure_restores_old_or_missing_managed_files(self):
        from test_ssh_error_contract import SshErrorContractTest, HARDENING, SOCKET
        for existing in (False, True):
            r, calls, main, files = SshErrorContractTest().run_ssh(
                failure='sshd -t', existing_targets=existing, snapshots=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(main, '#Port 22\n')
            self.assertEqual(files[HARDENING], b'# previous live config\n' if existing else None)
            self.assertEqual(files[SOCKET], b'# previous live config\n' if existing else None)
            self.assertNotIn('systemctl restart', calls)
            self.assertNotIn('systemctl reload', calls)
            self.assertEqual(calls.count('preflight\n'), 1)  # read-only preflight only

    def test_foreign_listener_stops_before_persistence(self):
        from test_ssh_error_contract import SshErrorContractTest
        r, calls, main = SshErrorContractTest().run_ssh(extra_setup='check_ssh_port() { return 4; }')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(main, '#Port 22\n')
        self.assertNotIn('systemctl restart', calls)

    def test_service_mode_never_creates_socket_override(self):
        from test_ssh_error_contract import SshErrorContractTest, SOCKET
        r, calls, main, files = SshErrorContractTest().run_ssh(mode='service', snapshots=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(files[SOCKET])
        self.assertIn('Port 5829', main)

    def test_rollback_failure_is_fatal(self):
        from test_ssh_error_contract import SshErrorContractTest
        setup = '''
eval "$(declare -f access_safety | command sed '1s/access_safety/original_access_safety/')"
access_safety() { if [[ "$1" == restore ]]; then return 23; fi; original_access_safety "$@"; }
'''
        r, calls, _ = SshErrorContractTest().run_ssh(extra_setup=setup, failure='sshd -t')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('FATAL', r.stderr)
        self.assertIn('/etc/ssh/sshd_config', r.stderr)
        self.assertNotIn('systemctl restart', calls)


@unittest.skipUnless(sys.platform.startswith('linux'), 'directory-descriptor safety requires Linux')
class AccessFilesystemTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / 'custom-home'
        self.home.mkdir(mode=0o700)
        self.ssh = self.home / '.ssh'
        self.ssh.mkdir(mode=0o700)
        self.key = self.ssh / 'authorized_keys'
        self.key.write_bytes(b'# unrelated\nold options key\n')
        self.key.chmod(0o600)
        self.old = self.key.read_bytes()

    def key_run(self, action='append', program=PROGRAM):
        return run('key', self.home, os.getuid(), os.getgid(), action,
                   data='new key\n', program=program)

    def test_atomic_append_permissions_and_lines(self):
        r = self.key_run()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.key.read_bytes(), self.old + b'new key\n')
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.key.stat().st_uid, os.getuid())

    def test_unsafe_write_permissions_rejected_without_chown(self):
        for path in (self.home, self.ssh, self.key):
            old_mode = path.stat().st_mode & 0o777
            path.chmod(old_mode | 0o020)
            r = self.key_run()
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(self.key.read_bytes(), self.old)
            path.chmod(old_mode)

    def test_real_systemd_parser_accepts_preserved_socket_addresses(self):
        self.assertIsNotNone(shutil.which('systemd-analyze'))
        for evidence in (SOCKET, SOCKET.replace('0.0.0.0', '192.0.2.5').replace('[::]', '[2001:db8::5]')):
            planned = run('socket', 5829, data=evidence)
            self.assertEqual(planned.returncode, 0, planned.stderr)
            unit = self.home / 'fixture.socket'
            unit.write_text(planned.stdout.split('\n', 1)[1])
            (self.home / 'fixture.service').write_text('[Service]\nExecStart=/usr/bin/true\n')
            r = subprocess.run(['systemd-analyze', 'verify', '--man=no', str(unit)],
                               capture_output=True, text=True, timeout=15)
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_symlink_directory_rejected(self):
        other = self.home / 'other'
        self.ssh.rename(other)
        self.ssh.symlink_to(other, target_is_directory=True)
        self.assertNotEqual(self.key_run().returncode, 0)
        self.assertEqual((other / 'authorized_keys').read_bytes(), self.old)

    def test_special_targets_rejected(self):
        for kind in ('symlink', 'dangling', 'fifo', 'directory'):
            with self.subTest(kind=kind):
                self.key.unlink()
                if kind in ('symlink', 'dangling'):
                    target = self.home / 'other-key'
                    if kind == 'symlink':
                        target.write_bytes(b'unchanged')
                    elif target.exists():
                        target.unlink()
                    self.key.symlink_to(target)
                elif kind == 'fifo':
                    os.mkfifo(self.key)
                else:
                    self.key.mkdir()
                r = self.key_run()
                self.assertNotEqual(r.returncode, 0)
                self.assertNotIn('new key', r.stderr)
                if self.key.is_dir():
                    self.key.rmdir()
                else:
                    self.key.unlink()
                self.key.write_bytes(self.old)

    def test_injected_pre_replace_failures_keep_live_bytes(self):
        for token in ('secrets.token_hex(16)', 'stream.write(data)', 'os.fchown(f, uid, gid)',
                      'os.fchmod(f, mode)', 'os.fsync(f)', 'os.replace(temp, name, src_dir_fd=fd, dst_dir_fd=fd)'):
            with self.subTest(token=token):
                program = PROGRAM.replace(token, '(_ for _ in ()).throw(OSError("injected"))')
                self.assertNotEqual(self.key_run(program=program).returncode, 0)
                self.assertEqual(self.key.read_bytes(), self.old)
                self.assertEqual(list(self.ssh.glob('.tunevps-access-*')), [])

    def test_target_substitution_detected(self):
        code = "os.rename(name, name + '.old', src_dir_fd=fd, dst_dir_fd=fd)\n        os.symlink('/dev/null', name, dir_fd=fd)\n        "
        r = self.key_run(program=PROGRAM.replace('now = read_at(fd, name)', code + 'now = read_at(fd, name)'))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.ssh / 'authorized_keys.old').read_bytes(), self.old)

    def test_parent_substitution_detected(self):
        code = "os.rename(parent, parent + '.old')\n        os.mkdir(parent)\n        "
        r = self.key_run(program=PROGRAM.replace('same_directory(fd, parent)\n        os.replace', code + 'same_directory(fd, parent)\n        os.replace'))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.home / '.ssh.old/authorized_keys').read_bytes(), self.old)

    def test_snapshots_restore_all_bytes_metadata_and_missing(self):
        missing = self.ssh / 'generated'
        snapshot = run('snapshot', self.key, missing)
        self.assertEqual(snapshot.returncode, 0, snapshot.stderr)
        stamp = self.key.stat().st_mtime_ns
        self.key.write_bytes(b'changed')
        self.key.chmod(0o644)
        missing.write_bytes(b'generated')
        r = run('restore', data=snapshot.stdout)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.key.read_bytes(), self.old)
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.key.stat().st_mtime_ns, stamp)
        self.assertFalse(missing.exists())

    def test_restore_failure_names_path(self):
        snapshot = run('snapshot', self.key)
        self.key.unlink()
        self.key.mkdir()
        r = run('restore', data=snapshot.stdout)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('FATAL', r.stderr)
        self.assertIn(str(self.key), r.stderr)


if __name__ == '__main__':
    unittest.main()
