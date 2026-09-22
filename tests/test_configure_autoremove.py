"""Real autoremove function, stubbed apt/TTY, temporary configuration only."""
import os
from atomic_support import HELPER
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_part2_error_propagation import PART2, STEPS, SOURCE

FUNCTION = 'configure_autoremove() {' + SOURCE.split('configure_autoremove() {', 1)[1].split('\nconfigure_needrestart()', 1)[0]
SUCCESS = 'Удаление неиспользуемых пакетов завершено'
POLICY = ('Unattended-Upgrade::Remove-Unused-Dependencies "false";\n'
          'Unattended-Upgrade::Remove-New-Unused-Dependencies "false";\n')


FUNCTION = HELPER + "\n" + FUNCTION


class ConfigureAutoremoveTest(unittest.TestCase):
    def run_setup(self, mode='success', answer='y', part2=False, repeat=False, errexit=False, count=2):
        with tempfile.TemporaryDirectory(prefix='autoremove test ') as tmp:
            root = Path(tmp)
            target = root / '50auto-remove'
            if mode == 'open':
                target.mkdir()
            prelude = r'''
set -o pipefail
section() { :; }
info() { echo "INFO: $*"; }
ok() { echo "OK: $*"; }
error() { echo "ERROR: $*" >&2; }
cat() {
  [ "$MODE" != write ] || return 23
  if [ "$MODE" = partial ]; then printf partial; return 23; fi
  command cat "$@"
}
ask() {
  echo "ASK:$1" >> "$ROOT/calls"
  [ "$MODE" != ask ] || return 23
  printf -v "$2" '%s' "$ANSWER"
}
apt-get() {
  echo "$*" >> "$ROOT/calls"
  case "$*" in
    '--dry-run autoremove')
      if [ "$MODE" = dry ]; then echo 'Remv partial [1]'; echo 'simulation failed' >&2; return 23; fi
      if [ "$MODE" = empty ] || [ -f "$ROOT/applied" ]; then echo '0 to remove'; return 0; fi
      for ((i=1; i<=COUNT; i++)); do echo "Remv pkg$i [1]"; done ;;
    'autoremove -y --purge')
      [ "$MODE" != apply ] || return 23
      : > "$ROOT/applied" ;;
    *) echo 'unexpected apt command' >&2; return 98 ;;
  esac
}
'''
            stubs = '\n'.join(f'{name}() {{ echo CALL:{name}; }}'
                              for name in STEPS if name != 'configure_autoremove')
            function = FUNCTION.replace('/etc/apt/apt.conf.d/50auto-remove', '"$ROOT/50auto-remove"')
            invoke = 'part2_setup' if part2 else 'configure_autoremove'
            script = prelude + function + '\n' + stubs + '\n' + PART2 + '\n'
            script += 'set -e\n' if errexit else ''
            script += f'{invoke} || exit $?\n' * (2 if repeat else 1)
            result = subprocess.run([os.environ.get('BASH', 'bash')], input=script,
                                    text=True, encoding='utf-8', capture_output=True, timeout=10,
                                    env={**os.environ, 'ROOT': root.as_posix(), 'MODE': mode,
                                         'ANSWER': answer, 'COUNT': str(count)})
            calls = (root / 'calls').read_text(encoding='utf-8').splitlines() if (root / 'calls').exists() else []
            policy = target.read_text() if target.is_file() else None
            return result, calls, policy

    def test_failures_stop_without_false_completion(self):
        for mode in ('dry', 'apply', 'ask', 'open', 'write', 'partial'):
            for part2 in (False, True):
                for errexit in (False, True):
                    with self.subTest(mode=mode, part2=part2, errexit=errexit):
                        result, calls, _ = self.run_setup(mode, part2=part2, errexit=errexit)
                        output = result.stdout + result.stderr
                        self.assertNotEqual(result.returncode, 0, output)
                        self.assertIn('ERROR:', output)
                        self.assertNotIn(SUCCESS, output)
                        self.assertNotIn('Часть 2 завершена', output)
                        self.assertNotIn('CALL:configure_needrestart', output)
                        self.assertEqual(calls.count('autoremove -y --purge'), int(mode == 'apply'))
                        if mode in ('open', 'write', 'partial'):
                            self.assertEqual(calls, [])
                            self.assertNotIn('Автоудаление зависимостей отключено', output)
                        if mode == 'dry':
                            self.assertFalse(any(c.startswith('ASK:') for c in calls))

    def test_success_and_voluntary_noops(self):
        for mode, answer in [('success', 'y'), ('success', 'Y'), ('empty', 'y'),
                             ('success', ''), ('success', 'n'), ('success', 'yes')]:
            for part2 in (False, True):
                for errexit in (False, True):
                    with self.subTest(mode=mode, answer=answer, part2=part2, errexit=errexit):
                        result, calls, policy = self.run_setup(mode, answer, part2, errexit=errexit)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertNotIn('ERROR:', result.stdout + result.stderr)
                        self.assertEqual(policy, POLICY)
                        applied = mode == 'success' and answer in ('y', 'Y')
                        self.assertEqual(calls.count('autoremove -y --purge'), int(applied))
                        self.assertEqual(result.stdout.count(SUCCESS), int(applied))
                        self.assertEqual(calls.count('--dry-run autoremove'), 1)
                        self.assertEqual(result.stdout.count('Часть 2 завершена'), int(part2))
                        if mode == 'empty':
                            self.assertIn('Нет пакетов для удаления', result.stdout)
                            self.assertFalse(any(c.startswith('ASK:') for c in calls))
                        else:
                            self.assertIn('ASK:Удалить эти пакеты сейчас? [y/N]: ', calls)
                            if not applied:
                                self.assertIn('Пропущено.', result.stdout)

    def test_repeated_invocation(self):
        for mode, answer in [('success', 'y'), ('empty', 'y'), ('success', 'n')]:
            with self.subTest(mode=mode, answer=answer):
                result, calls, policy = self.run_setup(mode, answer, repeat=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(policy, POLICY)
                self.assertEqual(calls.count('--dry-run autoremove'), 2)
                self.assertEqual(calls.count('autoremove -y --purge'), int(mode == 'success' and answer == 'y'))

    def test_preview_is_single_and_limited_to_twenty(self):
        result, calls, _ = self.run_setup(answer='n', count=25)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count('--dry-run autoremove'), 1)
        self.assertIn('Найдено 25 пакетов', result.stdout)
        self.assertIn('  - pkg20\n', result.stdout)
        self.assertNotIn('  - pkg21\n', result.stdout)
        self.assertIn('... и ещё 5', result.stdout)


if __name__ == '__main__':
    unittest.main()
