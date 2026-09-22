"""Extracted production functions, temporary files, stubbed probes/network/runner."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'tunevps.sh').read_text(encoding='utf-8')


def function(name, end):
    return name + SOURCE.split(name, 1)[1].split(end, 1)[0]


FINAL = function('final_check() {', '\npart2_setup()')
REMOTE = function('run_remote_diagnostic() (', '\nfinal_check()')
PART3 = function('part3_tests() {', '\nwhile true; do')
PORT = function('check_ssh_port() {', '\nif [ "$EUID"')
UFW = function('ufw_is_active() {', '\n# Если UFW')
PASSWORD = function('ask_password() {', '\nset_pin_password()')
MENU = 'while true; do' + SOURCE.rsplit('while true; do', 1)[1]
LOGGING = '''
set -o pipefail
section() { :; }
ok() { echo "OK:$*"; }
warn() { echo "WARN:$*"; }
info() { echo "INFO:$*"; }
error() { echo "ERROR:$*" >&2; }
'''


class DiagnosticsExternalTest(unittest.TestCase):
    def run_shell(self, body, setup=None, **env):
        with tempfile.TemporaryDirectory(prefix='diagnostic test ') as tmp:
            root = Path(tmp)
            (root / '.zshrc').touch()
            if setup:
                setup(root)
            result = subprocess.run(
                [os.environ.get('BASH', 'bash')], input=LOGGING + body,
                cwd=tmp, env=dict(os.environ, USER_HOME=root.as_posix(),
                                  TMPDIR=root.as_posix(), SSH_PORT='5829',
                                  CURRENT_USER='isolated', IS_MINIMIZED='false', **env),
                text=True, encoding='utf-8', capture_output=True, timeout=15)
            result.leftovers = [p.name for p in root.glob('tunevps-diagnostic.*')]
            result.calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
            return result

    def final(self, override=''):
        prelude = '''
install() { :; }
ss() { echo 'LISTEN 0 128 *:5829 *:*'; }
systemctl() { if [ "$1" = show ]; then echo 1048576; fi; }
sshd() {
  if [ "$1" = -T ]; then
    echo SNAPSHOT >> calls
    printf '%s\\n' 'port 5829' 'passwordauthentication no' 'pubkeyauthentication yes' 'permitrootlogin no' 'kbdinteractiveauthentication no' 'maxauthtries 3'
  fi
}
sysctl() { echo bbr; }
swapon() { echo /swapfile; }
ufw() { echo 'Status: active'; }
command() { [ "$*" != '-v zoxide' ] || return 1; builtin command "$@"; }
'''
        return self.run_shell(prelude + PORT + UFW + FINAL + override + '\nfinal_check\n')

    def test_one_snapshot_optional_absence_nonfatal(self):
        r = self.final()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.calls, 'SNAPSHOT\n')
        self.assertIn('zoxide НЕ установлен', r.stdout)
        self.assertIn('Powerlevel10k не найден', r.stdout)

    def test_sshd_failure_discards_partial_snapshot(self):
        for output in ('', "echo 'passwordauthentication no'"):
            r = self.final(f'\nsshd() {{ if [ "$1" = -T ]; then {output or ":"}; return 23; fi; }}')
            self.assertEqual(r.returncode, 1)
            self.assertIn('sshd -T', r.stderr)
            self.assertNotIn('OK:passwordauthentication', r.stdout)

    def test_each_required_ssh_field_missing_or_mismatched(self):
        fields = {'port': '5829', 'passwordauthentication': 'no', 'pubkeyauthentication': 'yes',
                  'permitrootlogin': 'no', 'kbdinteractiveauthentication': 'no', 'maxauthtries': '3'}
        for field in fields:
            for value in ('', 'wrong'):
                lines = [f'{k} {v}' for k, v in fields.items() if k != field]
                if value:
                    lines.append(f'{field} {value}')
                output = '\n'.join(lines)
                with self.subTest(field=field, value=value):
                    r = self.final(f"\nsshd() {{ [ \"$1\" != -T ] || printf '%s\\n' '{output}'; }}")
                    self.assertEqual(r.returncode, 1)
                    self.assertIn(field, r.stderr)

    def test_critical_probes_fail_including_partial_output(self):
        for override, diagnostic in [
            ('install() { return 23; }', '/run/sshd'),
            ("ss() { echo 'LISTEN 0 128 *:5829 *:*'; return 23; }", 'listener'),
            ('sysctl() { echo bbr; return 23; }', 'алгоритм'),
            ('swapon() { echo /swapfile; return 23; }', 'swap'),
            ("ufw() { echo 'Status: active'; return 23; }", 'UFW'),
            ("ufw() { echo unknown; }", 'UFW'),
            ('systemctl() { if [ "$1" = show ]; then echo 1048576; return 23; fi; }', 'DefaultLimitNOFILE'),
            ('systemctl() { :; }', 'DefaultLimitNOFILE'),
        ]:
            with self.subTest(override=override):
                r = self.final('\n' + override)
                self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
                self.assertIn(diagnostic, r.stderr)

    def test_benign_states_not_probe_failures(self):
        r = self.final('''
sysctl() { echo cubic; }
swapon() { :; }
ufw() { echo 'Status: inactive'; }
systemctl() { if [ "$1" = show ]; then echo 65536; fi; }
''')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('cubic', r.stdout)
        self.assertIn('Активный swap отсутствует', r.stdout)
        self.assertNotIn('RAM', r.stdout)
        self.assertIn('UFW НЕ активен', r.stdout)

    def test_listener_absent_vs_command_failure(self):
        for stub, status in [('ss() { :; }', 1), ('ss() { return 23; }', 2),
                             ("ss() { echo 'LISTEN 0 128 *:5829 *:*'; }", 0)]:
            r = self.run_shell(PORT + stub + '\ncheck_ssh_port\n')
            self.assertEqual(r.returncode, status)

    def remote(self, choice='1', mode='success', extra='', menu=False):
        prelude = r'''
ask() { printf -v "$2" '%s' "$CHOICE"; return "${ASK_STATUS:-0}"; }
curl() {
  echo "CURL:$*" >> calls
  [ "$1" = --fail ] || return 91
  local output
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then output="$2"; shift; fi
    shift
  done
  case "$MODE" in
    download-fail) return 23 ;;
    partial) printf 'echo partial\n' > "$output"; return 23 ;;
    empty) : > "$output" ;;
    write-fail) return 23 ;;
    *) printf '#!/bin/bash\necho safe-fixture\n' > "$output" ;;
  esac
}
wget() { echo FORBIDDEN_WGET >> calls; return 99; }
bash() {
  if [ "$1" = -n ]; then
    echo SYNTAX >> calls
    [ "$MODE" != syntax-fail ] || return 2
  else
    echo "RUN:$*" >> calls
    [ "$MODE" != runner-fail ] || return 17
  fi
}
sysbench() { echo "SYSBENCH:$*" >> calls; return 19; }
'''
        if menu:
            extra += '''
asks=0
ask() { asks=$((asks+1)); case "$asks" in 1) choice=3;; 2) choice=9;; *) choice=0;; esac; }
pause() { echo PAUSED; }
'''
        return self.run_shell(prelude + REMOTE + PART3 + extra + '\n' + (MENU if menu else 'part3_tests\n'),
                              CHOICE=choice, MODE=mode)

    def test_each_choice_download_failure_partial_empty_never_runs(self):
        for choice in map(str, range(1, 9)):
            for mode in ('download-fail', 'partial', 'empty', 'write-fail'):
                with self.subTest(choice=choice, mode=mode):
                    r = self.remote(choice, mode)
                    self.assertNotEqual(r.returncode, 0)
                    self.assertNotIn('RUN:', r.calls)
                    self.assertNotIn('SYNTAX', r.calls)
                    self.assertEqual(r.leftovers, [])

    def test_success_urls_flags_and_exact_runner_arguments(self):
        cases = [
            ('https://ipregion.vrnt.xyz', ''),
            ('https://github.com/vernette/censorcheck/raw/master/censorcheck.sh', '--mode geoblock'),
            ('https://github.com/vernette/censorcheck/raw/master/censorcheck.sh', '--mode dpi'),
            ('https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh', ''),
            ('https://yabs.sh', '-4'), ('https://IP.Check.Place', '-l en'),
            ('https://bench.sh', ''), ('https://Check.Place', '-EI')]
        for choice, (url, args) in enumerate(cases, 1):
            with self.subTest(choice=choice):
                r = self.remote(str(choice))
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn('--proto =https --proto-redir =https', r.calls)
                self.assertIn(url + '\n', r.calls)
                runner = next(line for line in r.calls.splitlines() if line.startswith('RUN:'))
                self.assertRegex(runner, r'^RUN:-- .*/tunevps-diagnostic\.[^ ]+' + (' ' + args if args else '') + '$')
                self.assertLess(r.calls.index('SYNTAX'), r.calls.index('RUN:'))
                self.assertEqual(r.leftovers, [])

    def test_syntax_and_runner_failure(self):
        for mode, status in [('syntax-fail', 2), ('runner-fail', 17)]:
            r = self.remote(mode=mode)
            self.assertEqual(r.returncode, status)
            self.assertEqual('RUN:' in r.calls, mode == 'runner-fail')
            self.assertEqual(r.leftovers, [])

    def test_temp_creation_nonregular_and_cleanup_failures(self):
        for extra in ['mktemp() { return 23; }',
                      'mktemp() { echo "$TMPDIR/missing"; }']:
            r = self.remote(extra=extra)
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn('RUN:', r.calls)
            self.assertNotIn('CURL:', r.calls)
        r = self.remote(extra='rm() { return 23; }')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('удалить', r.stderr)
        self.assertIn('RUN:', r.calls)
        r = self.remote(mode='partial', extra='rm() { return 23; }')
        self.assertEqual(r.returncode, 23)
        self.assertNotIn('RUN:', r.calls)

    def test_download_target_changed_to_nonregular_is_not_executed(self):
        r = self.remote(extra='''
curl() {
  local output
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then output="$2"; shift; fi
    shift
  done
  command rm -- "$output" && command mkdir -- "$output"
}
''')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('RUN:', r.calls)
        self.assertNotIn('SYNTAX', r.calls)

    def test_http_rejected_before_download(self):
        r = self.run_shell(REMOTE + '''
curl() { echo NETWORK; return 99; }
run_remote_diagnostic http://example.invalid
''')
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('NETWORK', r.stdout)

    def test_sysbench_error_and_menu_continues_visibly(self):
        r = self.remote('9')
        self.assertEqual(r.returncode, 19)
        self.assertIn('SYSBENCH:cpu run --threads=1', r.calls)
        self.assertIn('код 19', r.stderr)
        r = self.remote(menu=True)
        self.assertEqual(r.returncode, 0)
        self.assertIn('возврат в главное меню', r.stderr)
        self.assertIn('PAUSED', r.stdout)
        self.assertEqual(r.stdout.count('1) Первое обновление'), 2)

    def test_failed_partial_selection_and_back_invalid(self):
        for value in ('', '1'):
            r = self.remote(extra=f'ask() {{ choice="{value}"; return 1; }}')
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(r.calls, '')
        for choice in ('0', 'invalid'):
            r = self.remote(choice)
            self.assertEqual(r.returncode, 0)
            self.assertEqual(r.calls, '')
            self.assertEqual('Неверный выбор' in r.stdout, choice == 'invalid')

    def test_password_prompt_open_and_write_failure_no_read(self):
        for target, override in [('./absent/tty', ''), ('./tty', "printf() { return 23; }")]:
            r = self.run_shell(PASSWORD.replace('/dev/tty', target) + override + '''
read() { echo READ; }
ask_password prompt password
''')
            self.assertNotEqual(r.returncode, 0)
            self.assertNotIn('READ', r.stdout)

    def test_password_newline_failure_and_read_status_no_leak(self):
        for read_status in (0, 19):
            r = self.run_shell(PASSWORD.replace('/dev/tty', './tty') + f'''
printf() {{ [ "$1" != '\\n' ] || return 23; builtin printf "$@"; }}
read() {{ password='private-test-secret'; return {read_status}; }}
ask_password prompt password
''')
            self.assertEqual(r.returncode, read_status or 23)
            self.assertNotIn('private-test-secret', r.stdout + r.stderr)

    def test_workflow_scope_and_safe_whitespace_fallback(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/bash-syntax.yml').read_text()
        for expected in ('pull_request:', 'push:', 'branches: [main]', 'BASH: /bin/bash',
                         "PYTHONDONTWRITEBYTECODE: '1'", 'python3 -m unittest discover -s tests -v',
                         'bash -n tunevps.sh', 'git diff --check', 'fetch-depth: 0'):
            self.assertIn(expected, workflow)
        self.assertNotIn('paths:', workflow)
        self.assertNotIn('sudo ', workflow)
        self.assertNotIn('HEAD^', workflow)

    def test_bbr_availability_failure_preserves_persistence(self):
        body = function('configure_safe_sysctl() {', '\n# Глобальный лимит')
        for fail_at in (1, 2):
            # Counter is a file because the probe runs in command substitution.
            r = self.run_shell(body + f'''
modinfo() {{ return 1; }}
sysctl() {{
  local count=0
  [ ! -f count ] || read -r count < count
  count=$((count+1)); echo "$count" > count
  echo 'reno cubic bbr'
  [ "$count" -ne {fail_at} ] || return 23
}}
rm() {{ echo MUTATION; return 99; }}
mkdir() {{ echo MUTATION; return 99; }}
atomic_config() {{ echo MUTATION; return 99; }}
configure_safe_sysctl
''')
            self.assertEqual(r.returncode, 1)
            self.assertIn('Не удалось прочитать', r.stderr)
            self.assertNotIn('MUTATION', r.stdout)
            self.assertNotIn('BBR недоступен', r.stdout)

    def test_swap_partial_ram_measurement_stops_before_mutations(self):
        body = function('configure_swap() {', '\nauthorized_keys_has_key()')
        r = self.run_shell(body + '''
SWAP_SIZE=2G
SWAP_RAM_THRESHOLD_MB=2048
swapon() { :; }
free() { echo 'Mem: 1024 1 2 3'; return 23; }
fallocate() { echo MUTATION; return 99; }
rm() { echo MUTATION; return 99; }
configure_swap
''')
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn('измерить объём RAM', r.stderr)
        self.assertNotIn('MUTATION', r.stdout)


if __name__ == '__main__':
    unittest.main()
