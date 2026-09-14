"""Real key installation and part2, with temporary homes and isolated stubs."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_part2_error_propagation import PART2, STEPS


SOURCE = (Path(__file__).resolve().parents[1] / 'tunevps.sh').read_text(encoding='utf-8')
FUNCTIONS = 'ssh_key_fingerprint() {' + SOURCE.split('ssh_key_fingerprint() {', 1)[1].split('\nufw_is_active()', 1)[0]
PRELUDE = r'''
set -uo pipefail
ROOT="$PWD"
export TMPDIR="$ROOT"
PIN_USER=isolated_pin
PIN_HAS_KEY=true
mkdir -p "$ROOT/home/.ssh"
ssh-keygen -q -t ed25519 -N '' -f "$ROOT/new" || exit 90
ssh-keygen -q -t ed25519 -N '' -f "$ROOT/old" || exit 90
keys_path="$ROOT/home/.ssh/authorized_keys"
if [ "$EXISTING" = yes ]; then
  # Exercise the append path with an existing key lacking its trailing LF.
  printf '%s' "$(cat "$ROOT/old.pub")" > "$keys_path"
fi
section() { :; }
info() { echo "INFO: $*"; }
warn() { echo "WARN: $*"; }
error() { echo "ERROR: $*" >&2; }
ok() { echo "[OK] $*"; }
id() { return 0; }
getent() { printf 'isolated_pin:x:1000:1000::%s/home:/bin/bash\n' "$ROOT"; }
ask() {
  case "$2" in
    action) printf -v "$2" '%s' "$ACTION" ;;
    method) printf -v "$2" '%s' 2 ;;
    keyfile) printf -v "$2" '%s' "$ROOT/new.pub" ;;
    *) return 91 ;;
  esac
}
chmod() {
  local stage
  case "$2" in
    "$keys_path".tmp.*) stage=temp ;;
    "$ROOT/home/.ssh") stage=directory ;;
    "$keys_path") stage=keys ;;
    *) return 92 ;;
  esac
  echo "CHMOD:$stage:$1"
  [ "$FAILURE" != "$stage" ] || return 23
  command chmod "$@"
}
mv() {
  echo MV
  [ "$FAILURE" != mv ] || return 23
  command mv "$@"
}
chown() {
  echo CHOWN
  [ "$FAILURE" != chown ]
}
'''


class PinKeyPermissionsTest(unittest.TestCase):
    def run_install(self, failure='', existing=True, action='2', part2=False, repeat=False):
        stubs = '\n'.join(f'{name}() {{ echo STEP:{name}; }}'
                          for name in STEPS if name != 'configure_pin')
        invocation = 'part2_setup' if part2 else 'configure_pin'
        tail = f'''
set -e
status=0
{invocation} || status=$?
echo FLAG:$PIN_HAS_KEY
'''
        if repeat:
            tail += 'configure_pin || status=$?\necho REPEAT_FLAG:$PIN_HAS_KEY\n'
        tail += 'exit "$status"\n'
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [os.environ.get('BASH', 'bash')], cwd=directory,
                input=PRELUDE + FUNCTIONS + '\n' + stubs + '\n' + PART2 + tail,
                env=dict(os.environ, FAILURE=failure, EXISTING='yes' if existing else 'no', ACTION=action),
                text=True, encoding='utf-8', capture_output=True, timeout=30)
            root = Path(directory)
            keys = root / 'home/.ssh/authorized_keys'
            return (result, keys.read_bytes() if keys.exists() else None,
                    (root / 'old.pub').read_bytes().rstrip(b'\n'),
                    (root / 'new.pub').read_bytes(),
                    list((root / 'home/.ssh').glob('authorized_keys.tmp.*')))

    def assert_failure(self, result):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('FLAG:false', result.stdout)
        self.assertNotIn('[OK]', result.stdout)
        self.assertIn('ERROR:', result.stderr)

    def test_each_chmod_failure(self):
        for failure in ('temp', 'directory', 'keys'):
            for existing in (False, True):
                for action in ('2', '3'):
                    with self.subTest(failure=failure, existing=existing, action=action):
                        result, content, old, new, leftovers = self.run_install(failure, existing, action)
                        self.assert_failure(result)
                        mode = '700' if failure == 'directory' else '600'
                        self.assertIn(f'Не удалось установить права {mode} на ', result.stderr)
                        self.assertEqual(leftovers, [])
                        if failure == 'temp':
                            self.assertNotIn('MV', result.stdout)
                            self.assertNotIn('CHOWN', result.stdout)
                            self.assertEqual(content, old if existing else None)
                        else:
                            self.assertIn('MV', result.stdout)
                            self.assertIn('CHOWN', result.stdout)
                            self.assertEqual(content, old + b'\n' + new if existing and action == '2' else new)
                        if failure == 'directory':
                            self.assertNotIn('CHMOD:keys:', result.stdout)

    def test_real_part2_propagates_each_chmod_failure(self):
        for failure in ('temp', 'directory', 'keys'):
            with self.subTest(failure=failure):
                result, *_ = self.run_install(failure, part2=True)
                self.assert_failure(result)
                self.assertIn('Настройка пользователя isolated_pin завершилась ошибкой', result.stderr)
                self.assertNotIn('Часть 2 завершена', result.stdout + result.stderr)
                self.assertNotIn('STEP:configure_ssh', result.stdout)

    def test_happy_path_and_duplicate_are_idempotent(self):
        for existing in (False, True):
            with self.subTest(existing=existing):
                result, content, old, new, leftovers = self.run_install(existing=existing, repeat=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('FLAG:true', result.stdout)
                self.assertIn('REPEAT_FLAG:true', result.stdout)
                self.assertEqual(result.stdout.count('[OK] Ключ для isolated_pin установлен'), 1)
                self.assertEqual(result.stdout.count('\nMV\n'), 1)
                self.assertLess(result.stdout.index('CHMOD:keys:600'), result.stdout.index('[OK]'))
                self.assertEqual(content, old + b'\n' + new if existing else new)
                self.assertEqual(leftovers, [])

    def test_replace_happy_path(self):
        result, content, _, new, _ = self.run_install(action='3')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(content, new)
        self.assertIn('FLAG:true', result.stdout)

    def test_existing_mv_and_chown_guards(self):
        for failure in ('mv', 'chown'):
            with self.subTest(failure=failure):
                result, *_ = self.run_install(failure)
                self.assert_failure(result)

    def test_real_part2_happy_path(self):
        result, *_ = self.run_install(part2=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('FLAG:true', result.stdout)
        self.assertIn('STEP:final_check', result.stdout)
        self.assertEqual(result.stdout.count('Часть 2 завершена'), 1)


if __name__ == '__main__':
    unittest.main()
