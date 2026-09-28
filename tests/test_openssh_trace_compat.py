"""Captured 10.2 diagnostics and live temporary-config parser checks."""
import getpass
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_access_release_blockers import run


FIXTURE = Path(__file__).parent / 'fixtures' / 'openssh-10.2'
TRACE = (FIXTURE / 'stderr.txt').read_text() + (FIXTURE / 'stdout.txt').read_text()


class CapturedTraceTest(unittest.TestCase):
    def check(self, trace, expected):
        result = run('effective', '/home/pin', 'pin', 'checked-context', data=trace)
        self.assertEqual(result.returncode, expected, result.stderr)

    def test_captured_10_2_acceptance(self):
        self.check(TRACE, 0)

    def test_unknown_versions_rejected(self):
        for version in ('10.0', '10.1', '10.3', '10.20', '11.0'):
            with self.subTest(version=version):
                self.check(TRACE.replace('OpenSSH_10.2,', 'OpenSSH_' + version + ','), 2)

    def test_missing_malformed_diagnostics_rejected(self):
        for trace in ('', TRACE.replace('debug1: sshd version', 'unknown version'),
                      TRACE.replace('debug2: parse_server_config_depth:', 'unknown parse:'),
                      TRACE.replace("' on line 1", "'"),
                      TRACE.replace("' on line 1", "' on line zero"),
                      TRACE.replace("' on line 1", "' on line 0"),
                      TRACE.replace("' on line 1", "' on line 1 extra")):
            self.check(trace, 2)

    def test_10_2_match_and_key_restrictions_preserved(self):
        for old, new in (("Match User pin", "Match Address 192.0.2.0/24"),
                         ("Match User pin", "Match LocalPort 22"),
                         ('authorizedkeysfile %h/.ssh/authorized_keys', 'authorizedkeysfile .ssh/unused'),
                         ('pubkeyauthentication yes', 'pubkeyauthentication no'),
                         ('authenticationmethods publickey', 'authenticationmethods publickey,password')):
            self.check(TRACE.replace(old, new), 2)


@unittest.skipUnless(sys.platform.startswith('linux'), 'real OpenSSH requires Linux')
class LiveTraceTest(unittest.TestCase):
    def test_include_expanded_match_trace_and_effective_policy(self):
        user = getpass.getuser()
        with tempfile.TemporaryDirectory(prefix='pr30-live-trace-') as folder:
            root = Path(folder)
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(root / 'key')],
                           check=True, capture_output=True, timeout=10)
            config = root / 'sshd_config'
            include = root / 'included.conf'
            config.write_text(f'HostKey {root}/key\nPidFile {root}/pid\nUsePAM no\n'
                              f'PubkeyAuthentication yes\nAuthenticationMethods publickey\nInclude {include}\n')
            for expression, path, expected in (
                    (f'User {user}', '%h/.ssh/authorized_keys', 0),
                    ('all', '.ssh/authorized_keys', 0),
                    (f'User {user}', '.ssh/unused', 2),
                    ('Address 192.0.2.0/24', '.ssh/authorized_keys', 2),
                    ('LocalPort 22', '.ssh/authorized_keys', 2)):
                with self.subTest(expression=expression, path=path):
                    include.write_text(f'Match {expression}\n AuthorizedKeysFile {path}\nMatch all\n')
                    result = subprocess.run(
                        ['/usr/sbin/sshd', '-T', '-f', str(config), '-C',
                         f'user={user},host=127.0.0.1,addr=127.0.0.1,laddr=127.0.0.1,lport=5829', '-ddd'],
                        capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('debug1: sshd version OpenSSH_', result.stderr)
                    self.assertIn('debug2: parse_server_config_depth:', result.stderr)
                    self.assertIn(f"debug3: checking syntax for 'Match {expression}'", result.stderr)
                    self.assertIn('authorizedkeysfile ', result.stdout)
                    self.assertIn('pubkeyauthentication yes\n', result.stdout)
                    self.assertIn('authenticationmethods publickey\n', result.stdout)
                    checked = run('effective', '/home/' + user, user, 'checked-context',
                                  data=result.stderr + result.stdout)
                    self.assertEqual(checked.returncode, expected, checked.stderr)
