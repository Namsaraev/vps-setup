"""Real Linux OpenSSH parser plus isolated production callers; never start a daemon.

Linux deliberately requires sshd and ssh-keygen (no silent missing-tool skips).
All writes, including host keys and production /etc paths, stay in a temp dir.
Service, firewall, user-key and listener operations are stubs, not acceptance tests.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / 'tunevps.sh').read_text(encoding='utf-8')


def function(start, end):
    return start + SOURCE.split(start, 1)[1].split(end, 1)[0]


FUNCTIONS = '\n'.join((
    function('atomic_config() {', '\nconfigure_unattended_upgrades()'),
    function('set_sshd_line() {', '\nas_current_user()'),
    function('final_check() {', '\npart2_setup()'),
))
AUTH = ('PubkeyAuthentication yes\nPasswordAuthentication no\n'
        'KbdInteractiveAuthentication no\nPermitRootLogin no\nMaxAuthTries 3\n')
STUBS = r'''
set -eo pipefail
SSH_PORT=5829
PIN_USER=fixture
CURRENT_USER=fixture
USER_HOME="$ROOT/home"
IS_MINIMIZED=false
section() { :; }
info() { echo "INFO:$*"; }
ok() { echo "OK:$*"; }
warn() { echo "WARN:$*"; }
error() { echo "ERROR:$*" >&2; }
ask() { printf -v "$2" '%s' y; }
getent() { echo "fixture:x:1000:1000::$ROOT/home:/bin/bash"; }
authorized_keys_has_key() { return 0; }
install() { :; }
ensure_ufw_ssh_port() { :; }
systemctl() {
  echo "systemctl $*" >> "$ROOT/calls"
  case "$1" in
    is-active|is-enabled) [[ -e "$ROOT/applied" ]] ;;
    restart|reload) touch "$ROOT/applied" ;;
    show) echo 1048576 ;;
  esac
}
check_ssh_port() { [[ -e "$ROOT/applied" ]]; }
ss() { :; }
sleep() { :; }
sysctl() { echo bbr; }
swapon() { :; }
ufw() { :; }
ufw_is_active() { return 1; }
sshd() {
  case "$*" in -t|-T) ;; *) return 99 ;; esac
  /usr/sbin/sshd "$@" -f "$ROOT/etc/ssh/sshd_config"
}
'''


@unittest.skipUnless(sys.platform.startswith('linux'), 'real OpenSSH requires Linux')
class SshPortOpenSSHTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(Path('/usr/sbin/sshd').is_file(), 'Install openssh-server before Linux tests')
        self.assertIsNotNone(shutil.which('ssh-keygen'), 'ssh-keygen is required')
        self.tmp = tempfile.TemporaryDirectory(prefix='ssh-port-parser-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.main = self.root / 'etc/ssh/sshd_config'
        self.include = self.root / 'etc/ssh/sshd_config.d/00-vps-hardening.conf'
        self.include.parent.mkdir(parents=True)
        (self.root / 'home').mkdir()
        (self.root / 'home/.zshrc').touch()
        (self.root / 'calls').touch()
        self.key = self.root / 'host_key'
        result = subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.key)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.main.write_text(f'HostKey {self.key}\nPidFile {self.root}/sshd.pid\n'
                             f'Include {self.include.parent}/*.conf\n#Port 22\n')
        # Ubuntu include ordering: managed auth must still precede cloud-init.
        (self.include.parent / '50-cloud-init.conf').write_text('PasswordAuthentication yes\n')

    def parser(self, mode):
        result = subprocess.run(['/usr/sbin/sshd', mode, '-f', str(self.main)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def ports(self):
        self.parser('-t')
        return [line.split()[1] for line in self.parser('-T').splitlines()
                if line.startswith('port ')]

    def legacy(self):
        self.main.write_text(self.main.read_text().replace('#Port 22', 'Port 5829'))
        self.include.write_text('Port 5829\n' + AUTH)

    def run_call(self, call):
        functions = FUNCTIONS.replace('/etc/', str(self.root) + '/etc/').replace(
            '/run/sshd', str(self.root) + '/run/sshd')
        return subprocess.run([os.environ.get('BASH', '/bin/bash')],
                              input=STUBS + functions + '\n' + call + '\n',
                              env=dict(os.environ, ROOT=str(self.root)),
                              capture_output=True, text=True, timeout=20)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_parser_accepts_legacy_duplicate_and_exposes_old_scalar_bug(self):
        self.legacy()
        self.assertEqual(self.ports(), ['5829', '5829'])
        effective = self.parser('-T')
        # Exact old extraction: valid OpenSSH output was compared as one scalar.
        old = subprocess.check_output(['awk', '$1 == "port" {print $2}'],
                                      input=effective, text=True).strip()
        self.assertEqual(old, '5829\n5829')
        self.assertNotEqual(old, '5829')

    def test_generated_config_and_repeat_use_main_port_and_cloud_init_auth_order(self):
        self.assert_success(self.run_call('configure_ssh || exit $?'))
        self.assertEqual(self.ports(), ['5829'])
        self.assertIn('Port 5829\n', self.main.read_text())
        self.assertFalse(any(line.lower().startswith('port ') for line in self.include.read_text().splitlines()))
        effective = self.parser('-T').splitlines()
        for line in AUTH.lower().splitlines():
            self.assertIn(line, effective)
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in (self.main, self.include)}
        calls = (self.root / 'calls').read_text()
        repeated = self.run_call('configure_ssh || exit $?')
        self.assert_success(repeated)
        self.assertIn('SSH уже настроен', repeated.stdout)
        self.assertEqual(before, {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in before})
        self.assertEqual(calls, (self.root / 'calls').read_text())
        self.assert_success(self.run_call('final_check'))

    def test_legacy_repeat_fast_path_and_final_check_accept_identical_ports(self):
        self.legacy()
        (self.root / 'applied').touch()
        before = {p: p.read_bytes() for p in (self.main, self.include)}
        result = self.run_call('configure_ssh || exit $?\nfinal_check')
        self.assert_success(result)
        self.assertIn('SSH уже настроен', result.stdout)
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        self.assertNotIn('restart', (self.root / 'calls').read_text())

    def test_reapply_replaces_legacy_include_with_auth_only(self):
        self.legacy()
        self.include.write_text(self.include.read_text().replace('MaxAuthTries 3', 'MaxAuthTries 6'))
        self.assert_success(self.run_call('configure_ssh || exit $?\nfinal_check'))
        self.assertEqual(self.ports(), ['5829'])
        self.assertNotIn('Port 5829', self.include.read_text())

    def test_post_apply_and_final_accept_identical_port_from_another_include(self):
        (self.include.parent / '90-existing.conf').write_text('Port 5829\n')
        self.assert_success(self.run_call('configure_ssh || exit $?\nfinal_check'))
        self.assertEqual(self.ports(), ['5829', '5829'])

    def test_different_effective_port_is_not_hidden_by_deduplication(self):
        for ports in ('Port 22\nPort 5829\n', 'Port 5829\nPort 22\n'):
            with self.subTest(ports=ports):
                (self.include.parent / '90-existing.conf').write_text(ports)
                # Force the apply path without depending on listener state.
                self.include.write_text('MaxAuthTries 6\n')
                result = self.run_call('configure_ssh || exit $?')
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('ERROR:port=', result.stderr)
                self.assertIn('22', self.ports())
                result = self.run_call('final_check')
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('ERROR:port=', result.stderr)


if __name__ == '__main__':
    unittest.main()
