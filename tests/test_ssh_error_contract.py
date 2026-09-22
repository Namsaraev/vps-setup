"""Real SSH functions in a temporary filesystem; all operational commands stubbed."""
import os
from atomic_support import HELPER
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_part2_error_propagation import PART2, STEPS

SOURCE = (Path(__file__).resolve().parents[1] / 'tunevps.sh').read_text(encoding='utf-8')
FUNCTIONS = 'set_sshd_line() {' + SOURCE.split('set_sshd_line() {', 1)[1].split('\nas_current_user()', 1)[0]
HARDENING = '/etc/ssh/sshd_config.d/00-vps-hardening.conf'
SOCKET = '/etc/systemd/system/ssh.socket.d/99-vps-port.conf'
PRELUDE = r'''
set -o pipefail
SSH_PORT=5829
PIN_USER=fixture
section() { :; }
info() { echo "INFO:$*"; }
ok() { echo "OK:$*"; }
error() { echo "ERROR:$*" >&2; }
warn() { echo "WARN:$*"; }
ask() { printf -v "$2" '%s' y; }
getent() { echo "fixture:x:1000:1000::$ROOT/home:/bin/bash"; }
authorized_keys_has_key() { return 0; }
op() { echo "$*" >> "$ROOT/calls"; [[ "$*" != "$FAILURE" ]]; }
install() { op install; }
ensure_ufw_ssh_port() { op preflight; }
cp() { op cp && command cp "$@"; }
sed() { op sed && command sed "$@"; }
grep() {
  if [[ "$*" == *sshd_config* ]] && [[ "$FAILURE" == grep ]]; then return 2; fi
  command grep "$@"
}
echo() {
  if [[ "$*" == 'Port 5829' && "$FAILURE" == append ]]; then return 23; fi
  builtin echo "$@"
}
mkdir() { op "mkdir ${*: -1}" && command mkdir "$@"; }
cat() {
  local content
  content=$(command cat) || return $?
  if [[ "$content" == '[Socket]'* ]]; then op socket-write || return 23
  else op hardening-write || return 23; fi
  printf '%s\n' "$content"
}
systemctl() {
  case "$1" in
    is-active|is-enabled) [[ "$MODE" == socket ]]; return $? ;;
  esac
  op "systemctl $*" || return 23
  case "$1" in reload|restart) command touch "$ROOT/applied" ;; esac
}
sshd() {
  op "sshd $*" || return 23
  [[ "$1" == -t ]] && return 0
  if [[ -e "$ROOT/applied" ]] || { [[ -f "$ROOT/etc/ssh/sshd_config" ]] && command grep -q '^Port 5829$' "$ROOT/etc/ssh/sshd_config" 2>/dev/null; }; then
    printf '%s\n' 'port 5829' 'passwordauthentication no' 'pubkeyauthentication yes' 'permitrootlogin no' 'kbdinteractiveauthentication no' 'maxauthtries 3'
  else
    printf '%s\n' 'port 22' 'passwordauthentication yes'
  fi
}
check_ssh_port() { op listener && [[ -e "$ROOT/applied" ]]; }
ss() { :; }
sleep() { :; }
'''


FUNCTIONS = HELPER + "\n" + FUNCTIONS


class SshErrorContractTest(unittest.TestCase):
    def run_ssh(self, failure='', append=False, redirect='', outer=False,
                repeat=False, mode='socket', errexit=True, helper_stub=False, extra_setup="",
                existing_targets=False, snapshots=False):
        with tempfile.TemporaryDirectory(prefix='ssh-contract-') as tmp:
            root = Path(tmp)
            bash = os.environ.get('BASH', 'bash')
            posix = subprocess.check_output(
                [bash, '-c', 'cygpath -u "$1" 2>/dev/null || printf "%s" "$1"',
                 '_', root.as_posix()], text=True).strip()
            (root / 'etc/ssh').mkdir(parents=True)
            (root / 'home').mkdir()
            (root / 'blocked').mkdir()
            (root / 'calls').touch()
            (root / 'etc/ssh/sshd_config').write_text('# fixture\n' if append else '#Port 22\n', encoding='utf-8')
            if existing_targets:
                for target in (HARDENING, SOCKET):
                    path = root / target.lstrip('/')
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b'# previous live config\n')
            functions = FUNCTIONS.replace('/etc/', posix + '/etc/').replace('/run/sshd', posix + '/run/sshd')
            if redirect:
                target = posix + redirect
                functions = functions.replace('atomic_config ' + target + ' ',
                                              'atomic_config ' + posix + '/blocked ')

            stubs = '\n'.join(f'{name}() {{ echo STEP:{name}; }}' for name in STEPS if name != 'configure_ssh')
            if helper_stub:
                stubs += '\nset_sshd_line() { return 23; }\n'
            call = 'part2_setup' if outer else 'configure_ssh'
            script = PRELUDE + functions + '\n' + stubs + '\n' + PART2
            script += '\n' + extra_setup + '\n'
            script += '\nset -e\n' if errexit else '\nset +e\n'
            script += (call + ' || exit $?\n') * (2 if repeat else 1)
            env = dict(os.environ, ROOT=posix, FAILURE=failure.replace('/etc/', posix + '/etc/'), MODE=mode)
            result = subprocess.run([bash], input=script, env=env, text=True,
                                    encoding='utf-8', capture_output=True, timeout=15)
            calls = (root / 'calls').read_text(encoding='utf-8').replace(posix, '')
            main = root / 'etc/ssh/sshd_config'
            config = main.read_text(encoding='utf-8') if main.is_file() else None
            if snapshots:
                files = {target: (root / target.lstrip('/')).read_bytes()
                         for target in (HARDENING, SOCKET)}
                return result, calls, config, files
            return result, calls, config

    def assert_failed(self, result, calls):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('ERROR:', result.stderr)
        self.assertNotIn('OK:SSH слушает', result.stdout)
        self.assertNotIn('применён', result.stdout)
        self.assertNotIn('Часть 2 завершена', result.stdout)
        self.assertNotIn('STEP:configure_ufw', result.stdout)
        self.assertNotIn('listener', calls)
        self.assertNotIn('systemctl restart', calls)
        self.assertNotIn('systemctl reload ', calls)

    def test_each_critical_failure_propagates_through_real_part2(self):
        cases = [dict(helper_stub=True), dict(failure='grep'), dict(failure='sed'),
                 dict(failure='append', append=True),
                 dict(redirect='/etc/ssh/sshd_config', append=True),
                 dict(failure='mkdir /etc/ssh/sshd_config.d'),
                 dict(failure='mkdir /etc/systemd/system/ssh.socket.d'),
                 dict(failure='hardening-write'), dict(redirect=HARDENING),
                 dict(failure='socket-write'), dict(redirect=SOCKET),
                 dict(failure='systemctl daemon-reload')]
        for case in cases:
            for outer in (False, True):
                for errexit in (False, True):
                    with self.subTest(case=case, outer=outer, errexit=errexit):
                        result, calls, _ = self.run_ssh(**case, outer=outer, errexit=errexit)
                        self.assert_failed(result, calls)
                        if case.get('failure') in ('grep', 'sed', 'append') or case.get('helper_stub'):
                            self.assertNotIn('mkdir', calls)
                        if case.get('redirect') == HARDENING or case.get('failure') == 'hardening-write':
                            self.assertNotIn('sshd -t', calls)
                        if case.get('redirect') == SOCKET or case.get('failure') == 'socket-write':
                            self.assertNotIn('systemctl daemon-reload', calls)

    def test_existing_preflight_backup_runtime_guards(self):
        for failure in ('install', 'preflight', 'cp', 'sshd -T', 'sshd -t'):
            with self.subTest(failure=failure):
                result, calls, _ = self.run_ssh(failure=failure, outer=True)
                self.assert_failed(result, calls)

    def test_socket_and_service_happy_path_and_idempotency(self):
        for mode in ('socket', 'service'):
            for append in (False, True):
                with self.subTest(mode=mode, append=append):
                    result, calls, config = self.run_ssh(mode=mode, append=append, repeat=True, outer=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(config.count('Port 5829'), 1)
                    self.assertEqual(calls.count('cp\n'), 1)
                    self.assertIn('sshd -t\n', calls)
                    self.assertIn('Port 5829', config)
                    self.assertEqual(result.stdout.count('Часть 2 завершена'), 2)
                    self.assertIn('SSH уже настроен', result.stdout)
                    if mode == 'socket':
                        self.assertEqual(calls.count('systemctl daemon-reload\n'), 1)
                        self.assertIn('systemctl restart ssh.socket', calls)
                    else:
                        self.assertNotIn('daemon-reload', calls)
                        self.assertIn('systemctl reload ssh.service', calls)

    def test_listener_failure_keeps_status_presentation_only(self):
        result, calls, _ = self.run_ssh(failure='listener', outer=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('systemctl status ssh.socket ssh.service --no-pager', calls)
        self.assertNotIn('Часть 2 завершена', result.stdout)
        self.assertNotIn('OK:SSH слушает', result.stdout)


if __name__ == '__main__':
    unittest.main()
