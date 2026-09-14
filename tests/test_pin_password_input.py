"""Password input contracts; no real account commands or terminal are used."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_part2_error_propagation import PART2, STEPS

SOURCE = (Path(__file__).resolve().parents[1] / 'tunevps.sh').read_text(encoding='utf-8')
PASSWORD = 'ask_password() {' + SOURCE.split('ask_password() {', 1)[1].split('\npause()', 1)[0]
PIN = 'configure_pin() {' + SOURCE.split('configure_pin() {', 1)[1].split('\nconfigure_ssh()', 1)[0]
# Redirect only the terminal device to a disposable file. Keep the real read
# builtin for success, empty input, partial EOF and EOF paths.
PASSWORD = PASSWORD.replace('/dev/tty', './tty')
PRELUDE = r'''
set -uo pipefail
PIN_USER=isolated_pin
PIN_HAS_KEY=false
section() { :; }
info() { echo "INFO:$*"; }
warn() { echo "WARN:$*"; }
error() { echo "ERROR:$*" >&2; }
ok() { echo "OK:$*"; }
id() { [ "$EXISTING" = yes ]; }
getent() { printf 'isolated_pin:x:1000:1000::%s:/bin/bash\n' "$PWD"; }
authorized_keys_has_key() { return 1; }
yes_by_default() { return 0; }
ask() { printf -v "$2" '%s' 1; }
adduser() { echo ADDUSER; }
usermod() { echo USERMOD; }
read_count=0
read() {
  read_count=$((read_count + 1))
  echo READ >&2
  local token=${INPUTS%%,*}
  INPUTS=${INPUTS#*,}
  case "$token" in
    eof) builtin read "$@" < /dev/null ;;
    partial) builtin read "$@" < <(printf '%s' "$SECRET_A") ;;
    fail) return 23 ;;
    a) builtin read "$@" < <(printf '%s\n' "$SECRET_A") ;;
    b) builtin read "$@" < <(printf '%s\n' "$SECRET_B") ;;
    empty) builtin read "$@" < <(printf '\n') ;;
    *) return 91 ;;
  esac
}
chpasswd() {
  # Consume and compare silently; never pass password data to diagnostics.
  local payload
  payload=$(cat)
  [ "$payload" = "$PIN_USER:$SECRET_A" ] || return 92
  echo CHPASSWD
  return "$CHPASSWD_STATUS"
}
'''


class PinPasswordInputTest(unittest.TestCase):
    def run_case(self, inputs, invocation='set_pin_password', existing=True,
                 chpasswd=0, helper_failure=False):
        secrets = ('private-A-9! \\ value', 'private-B-8!')
        stubs = '\n'.join(f'{name}() {{ echo STEP:{name}; }}'
                          for name in STEPS if name != 'configure_pin')
        helper = 'set_pin_password() { return 23; }\n' if helper_failure else ''
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [os.environ.get('BASH', 'bash')], cwd=directory,
                input=PRELUDE + PASSWORD + '\n' + PIN + '\n' + stubs + '\n'
                      + PART2 + '\n' + helper + 'set -e\n'
                      + invocation + ' || exit $?\n',
                env=dict(os.environ, INPUTS=inputs, SECRET_A=secrets[0],
                         SECRET_B=secrets[1], EXISTING='yes' if existing else 'no',
                         CHPASSWD_STATUS=str(chpasswd)),
                text=True, encoding='utf-8', capture_output=True, timeout=10)
            logs = result.stdout + result.stderr + (Path(directory) / 'tty').read_text(
                encoding='utf-8') if (Path(directory) / 'tty').exists() else result.stdout + result.stderr
            for secret in secrets:
                # Boolean assertions deliberately avoid printing leaked values.
                self.assertFalse(secret in logs, 'password leaked into captured logs')
                self.assertFalse(secret.encode() in logs.encode(), 'password bytes leaked')
        return result

    def test_input_failures_stop_immediately(self):
        for inputs, status, reads in [('fail', 23, 1), ('a,fail', 23, 2),
                                      ('eof', 1, 1), ('a,eof', 1, 2),
                                      ('partial', 1, 1), ('a,b,fail', 23, 3)]:
            with self.subTest(inputs=inputs):
                result = self.run_case(inputs)
                self.assertEqual(result.returncode, status)
                self.assertEqual(result.stderr.count('READ\n'), reads)
                self.assertIn('ERROR:', result.stderr)
                self.assertNotIn('CHPASSWD', result.stdout)
                self.assertNotIn('OK:', result.stdout)

    def test_success_and_mismatch_retry(self):
        for inputs, reads in [('a,a', 2), ('a,b,a,a', 4), ('empty,empty,a,a', 4)]:
            with self.subTest(inputs=inputs):
                result = self.run_case(inputs)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stderr.count('READ\n'), reads)
                self.assertEqual(result.stdout.count('CHPASSWD'), 1)
                self.assertEqual(result.stdout.count('OK:Пароль'), 1)
                self.assertLess(result.stdout.index('CHPASSWD'), result.stdout.index('OK:'))
                if inputs.startswith('a,b'):
                    self.assertIn('Пароли не совпадают', result.stdout)
                if inputs.startswith('empty'):
                    self.assertIn('Пароль не может быть пустым', result.stdout)

    def test_chpasswd_failure_retries_then_input_failure_stops(self):
        result = self.run_case('a,a,fail', chpasswd=17)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(result.stdout.count('CHPASSWD'), 1)
        self.assertNotIn('OK:', result.stdout)
        self.assertIn('Не удалось установить пароль; попробуйте ещё раз', result.stderr)

    def test_configure_pin_propagates_helper_and_real_input_failure(self):
        for existing in (False, True):
            for helper in (False, True):
                with self.subTest(existing=existing, helper=helper):
                    result = self.run_case('fail', 'configure_pin', existing,
                                           helper_failure=helper)
                    self.assertEqual(result.returncode, 23 if existing else 1)
                    self.assertNotIn('CHPASSWD', result.stdout)
                    self.assertNotIn('OK:Пароль', result.stdout)
                    self.assertEqual('ADDUSER' in result.stdout, not existing)
                    self.assertEqual('USERMOD' in result.stdout, not existing)

    def test_real_part2_stops_on_input_failure(self):
        for existing in (False, True):
            for inputs in ('fail', 'a,fail', 'a,b,eof'):
                with self.subTest(existing=existing, inputs=inputs):
                    result = self.run_case(inputs, 'part2_setup', existing)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn('Часть 2 завершена', result.stdout + result.stderr)
                    self.assertNotIn('STEP:configure_ssh', result.stdout)

    def test_existing_user_success_and_real_part2_success(self):
        for invocation in ('configure_pin', 'part2_setup'):
            result = self.run_case('a,a', invocation)
            self.assertEqual(result.returncode, 0)
            self.assertNotIn('ADDUSER', result.stdout)
            self.assertNotIn('USERMOD', result.stdout)
            if invocation == 'part2_setup':
                self.assertEqual(result.stdout.count('Часть 2 завершена'), 1)


if __name__ == '__main__':
    unittest.main()
