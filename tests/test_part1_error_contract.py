"""Real part1/probe/menu code; all system commands and marker writes are stubs."""
import os
from pathlib import Path
import subprocess
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'tunevps.sh').read_text(encoding='utf-8')
PROBE, INIT = SOURCE.split('detect_minimized() {', 1)[1].split('\npart1_update() {', 1)[0].split('\nIS_MINIMIZED=false', 1)
PROBE = 'detect_minimized() {' + PROBE
INIT = 'IS_MINIMIZED=false' + INIT
PART1 = 'part1_update() {' + SOURCE.split('part1_update() {', 1)[1].split('\ninstall_packages()', 1)[0]
MENU = 'while true; do' + SOURCE.rsplit('while true; do', 1)[1]
DEFAULT = '''
set -o pipefail
section() { :; }
info() { echo "INFO:$*"; }
warn() { echo "WARN:$*"; }
error() { echo "ERROR:$*" >&2; }
ok() { echo "OK:$*"; }
yes_by_default() { [[ -z "$1" || "$1" =~ ^[Yy]$ ]]; }
FIRST_UPDATE_MARKER=/stub/marker
marker=false
excludes=false
installed=false
available=false
tools=false
failure=''
probe_failure=''
reply=n
reboot_reply=n
read_failure=0
read_mode=eof
reads=0
IS_MINIMIZED=false
dpkg-query() {
  [ "$installed" = true ] && echo 'ubuntu-standard installed'
  [ "$probe_failure" != dpkg ]
}
grep() {
  case "$probe_failure" in grep) return 2;; nomatch) return 1;; esac
  return 0
}
command() {
  case "$2" in
    unminimize)
      [ "$probe_failure" = unminimize ] && return 2
      [ "$available" = true ];;
    man|less)
      [ "$probe_failure" = command ] && return 2
      [ "$tools" = true ];;
    *) echo UNSTUBBED >&2; return 99;;
  esac
}
[() {
  if [[ "$1" == ! ]]; then
    shift
    ! [ "$@"
  elif [[ "$1" == -f && "$2" == /stub/marker ]]; then
    builtin [ "$marker" = true ]
  elif [[ "$1" == -f && "$2" == /etc/dpkg/dpkg.cfg.d/excludes ]]; then
    builtin [ "$excludes" = true ]
  else builtin [ "$@"; fi
}
ask() {
  reads=$((reads + 1))
  echo "ASK:$1"
  if [ "$reads" -eq "$read_failure" ]; then
    if [ "$read_mode" = eof ]; then read -r "$2" < /dev/null
    else read -r "$2" <&9; fi
    return $?
  fi
  case "$1" in
    Перезагрузить*) IFS= read -r "$2" <<< "$reboot_reply";;
    Выберите*) IFS= read -r "$2" <<< '1';;
    *) IFS= read -r "$2" <<< "$reply";;
  esac
}
apt-get() { echo "APT:$*"; [ "$failure" != "$1" ]; }
mkdir() { echo MKDIR; [ "$failure" != mkdir ]; }
dirname() { echo /stub; }
touch() { echo MARKER; [ "$failure" != touch ] || return 1; marker=true; }
yes() { printf 'y\n'; }
unminimize() { echo UNMINIMIZE; [ "$failure" != unminimize ]; }
sleep() { echo "SLEEP:$*"; [ "$failure" != sleep ]; }
reboot() { echo REBOOT; [ "$failure" != reboot ]; }
pause() { [ "$failure" != pause ] || return 1; echo PAUSE; exit 0; }
part2_setup() { return 99; }
part3_tests() { return 99; }
'''


class Part1ErrorContractTest(unittest.TestCase):
    def run_case(self, settings='', call='part1_update || exit $?', menu=False):
        return subprocess.run(
            [os.environ.get('BASH', 'bash')], input=DEFAULT + PROBE + '\n' + PART1
            + '\n' + settings + '\n' + (MENU if menu else call) + '\n',
            text=True, encoding='utf-8', capture_output=True, timeout=10)

    def failed(self, result, status=None):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        if status is not None:
            self.assertEqual(result.returncode, status, result.stderr)
        self.assertIn('ERROR:', result.stderr)
        self.assertNotIn('OK:Пакеты обновлены', result.stdout)
        self.assertNotIn('PAUSE', result.stdout)

    def test_probe_minimized(self):
        for settings in ('', 'excludes=true', 'excludes=true; probe_failure=nomatch'):
            self.assertEqual(self.run_case(settings, 'detect_minimized').returncode, 0)

    def test_probe_not_minimized(self):
        for settings in ('installed=true', 'tools=true', 'installed=true; excludes=true'):
            r = self.run_case(settings, 'detect_minimized')
            self.assertEqual(r.returncode, 1, r.stderr)
            self.assertNotIn('ERROR:', r.stderr)

    def test_probe_failures_distinct(self):
        for settings in ('probe_failure=dpkg', 'probe_failure=dpkg; installed=true',
                         'excludes=true; probe_failure=grep', 'probe_failure=command'):
            self.failed(self.run_case(settings, 'detect_minimized'), 2)

    def test_initialization_propagates_probe_failure(self):
        r = self.run_case('probe_failure=dpkg', INIT + '\necho CONTINUED')
        self.failed(r, 2)
        self.assertNotIn('CONTINUED', r.stdout)

    def test_initialization_flags(self):
        for settings, expected in (('', 'true'), ('installed=true', 'false')):
            r = self.run_case(settings, INIT + '\necho FLAG:$IS_MINIMIZED')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('FLAG:' + expected, r.stdout)

    def test_unminimize_install_failure(self):
        r = self.run_case('IS_MINIMIZED=true; reply=y; failure=install')
        self.failed(r)
        self.assertIn('APT:install -y unminimize', r.stdout)
        self.assertNotIn('\nUNMINIMIZE', r.stdout)
        self.assertNotIn('MARKER', r.stdout)

    def test_unminimize_failure_still_minimized(self):
        r = self.run_case('IS_MINIMIZED=true; reply=y; failure=unminimize')
        self.failed(r)
        self.assertNotIn('MARKER', r.stdout)
        self.assertNotIn('OK:unminimize', r.stdout)

    def test_unminimize_failure_reprobe_failure(self):
        r = self.run_case('IS_MINIMIZED=true; reply=y; failure=unminimize; probe_failure=dpkg')
        self.failed(r, 2)
        self.assertNotIn('OK:unminimize', r.stdout)

    def test_unminimize_nonzero_but_verified_complete(self):
        r = self.run_case('IS_MINIMIZED=true; reply=y; failure=unminimize; installed=true')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('OK:unminimize', r.stdout)

    def test_each_prompt_eof_and_read_error(self):
        for prompt in (1, 2):
            for mode in ('eof', 'closed'):
                r = self.run_case(f'IS_MINIMIZED=true; read_failure={prompt}; read_mode={mode}')
                self.failed(r)
                self.assertNotIn('REBOOT', r.stdout)
                if prompt == 1:
                    self.assertNotIn('APT:', r.stdout)

    def test_reboot_prompt_failure_without_unminimize(self):
        self.failed(self.run_case('read_failure=1'))

    def test_unneeded_and_refused_unminimize_success(self):
        for settings in ('', 'IS_MINIMIZED=true; reply=n', 'IS_MINIMIZED=true; reply=N'):
            r = self.run_case(settings)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertNotIn('UNMINIMIZE\n', r.stdout)
            self.assertNotIn('APT:install', r.stdout)
            self.assertIn('APT:full-upgrade -y', r.stdout)
            self.assertNotIn('REBOOT', r.stdout)

    def test_reboot_failure(self):
        self.failed(self.run_case('reboot_reply=y; failure=reboot'))

    def test_reboot_delay_failure(self):
        r = self.run_case('reboot_reply=y; failure=sleep')
        self.failed(r)
        self.assertNotIn('REBOOT', r.stdout)

    def test_unminimize_availability_probe_failure(self):
        r = self.run_case('IS_MINIMIZED=true; reply=y; probe_failure=unminimize')
        self.failed(r)
        self.assertNotIn('APT:install', r.stdout)

    def test_marker_survives_reboot_input_failure(self):
        r = self.run_case('read_failure=1',
                          'part1_update && exit 99\nread_failure=0\npart1_update || exit $?')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('ERROR:', r.stderr)
        self.assertEqual(r.stdout.count('APT:full-upgrade -y'), 1)
        self.assertEqual(r.stdout.count('APT:upgrade -y'), 1)
        self.assertEqual(r.stdout.count('MARKER'), 1)

    def test_empty_answers_preserve_yes_defaults(self):
        r = self.run_case('IS_MINIMIZED=true; reply=""; reboot_reply=""')
        self.assertEqual(r.returncode, 0, r.stderr)
        actions = [x for x in r.stdout.splitlines() if x.startswith(('APT:', 'UNMINIMIZE', 'SLEEP:', 'REBOOT'))]
        self.assertEqual(actions, ['APT:update', 'APT:install -y unminimize', 'UNMINIMIZE',
                                  'APT:update', 'APT:full-upgrade -y', 'SLEEP:5', 'REBOOT'])

    def test_existing_unminimize_skips_install(self):
        r = self.run_case('IS_MINIMIZED=true; reply=y; available=true')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn('APT:install', r.stdout)

    def test_repeat_marker_and_unminimize_state(self):
        r = self.run_case('IS_MINIMIZED=true; reply=y',
                          'part1_update || exit $?\npart1_update || exit $?')
        self.assertEqual(r.returncode, 0, r.stderr)
        for action in ('UNMINIMIZE\n', 'APT:full-upgrade -y', 'MARKER', 'APT:upgrade -y'):
            self.assertEqual(r.stdout.count(action), 1, r.stdout)

    def test_existing_critical_guards(self):
        for failure in ('update', 'full-upgrade', 'upgrade', 'mkdir', 'touch'):
            settings = f'failure={failure}' + ('; marker=true' if failure == 'upgrade' else '')
            r = self.run_case(settings)
            self.failed(r)
            self.assertNotIn('ASK:', r.stdout)

    def test_menu_propagates_part1_failures(self):
        for settings in ('failure=update', 'read_failure=2', 'reboot_reply=y; failure=reboot',
                         'IS_MINIMIZED=true; reply=y; failure=unminimize; probe_failure=dpkg'):
            self.failed(self.run_case(settings, menu=True))

    def test_menu_preserves_exact_status(self):
        r = self.run_case('part1_update() { return 23; }', menu=True)
        self.assertEqual(r.returncode, 23)
        self.assertNotIn('PAUSE', r.stdout)

    def test_menu_read_failure(self):
        self.failed(self.run_case('read_failure=1', menu=True))

    def test_menu_success_reaches_pause(self):
        r = self.run_case(menu=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('PAUSE', r.stdout)

    def test_menu_pause_failure_stops(self):
        r = self.run_case('failure=pause', menu=True)
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn('ERROR:', r.stderr)
        self.assertEqual(r.stdout.count('Выберите действие'), 1)


if __name__ == '__main__':
    unittest.main()
