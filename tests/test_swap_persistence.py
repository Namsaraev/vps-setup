"""Isolated persistence failures after mocked runtime activation; no real swap or fstab."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_configure_swap import FUNCTION, PRELUDE, FSTAB
from test_part2_error_propagation import PART2, STEPS


class SwapPersistenceTest(unittest.TestCase):
    def run_swap(self, failure='', active='', fstab=FSTAB, answer='',
                 outer=False, repeat=False, errexit=True):
        with tempfile.TemporaryDirectory(prefix='swap-persistence-') as tmp:
            root = Path(tmp)
            bash = os.environ.get('BASH', 'bash')
            posix = subprocess.check_output(
                [bash, '-c', 'cygpath -u "$1" 2>/dev/null || printf "%s" "$1"',
                 '_', root.as_posix()], text=True).strip()
            own = posix + '/swapfile'
            for name, content in [('active', active), ('fstab', fstab), ('calls', '')]:
                (root / name).write_text(content.replace('/swapfile', own), encoding='utf-8')
            if '/swapfile ' in active:
                (root / 'swapfile').touch()
            # A directory guarantees a real shell redirection failure, even as root.
            (root / 'blocked').mkdir()
            function = FUNCTION.replace('/etc/fstab', posix + '/fstab').replace('/swapfile', own)
            if failure == 'redirect':
                target = '>> ' + posix + '/fstab'
                self.assertEqual(function.count(target), 1)
                function = function.replace(target, '>> ' + posix + '/blocked')
            prelude = PRELUDE + r'''
ok() { echo "OK:$*"; }
error() { echo "ERROR:$*" >&2; }
printf() {
  if [[ "${2-}" == "$ROOT/swapfile none swap sw 0 0" ]]; then
    echo APPEND >> "$ROOT/calls"
    if [[ "$FAILURE" == write ]]; then
      echo 'printf: simulated write error' >&2
      return 1
    fi
  fi
  builtin printf "$@"
}
'''
            if not errexit:
                prelude += '\nset +e\n'
            stubs = '\n'.join(f'{name}() {{ echo STEP:{name}; }}'
                              for name in STEPS if name != 'configure_swap')
            call = 'part2_setup' if outer else 'configure_swap'
            # The conditional deliberately suppresses errexit, as the real guard does.
            invocation = f'{call} || exit $?\n'
            script = prelude + function + '\n' + stubs + '\n' + PART2 + '\n'
            script += invocation * (2 if repeat else 1)
            env = dict(os.environ, ROOT=posix, ANSWER=answer, RAM='1024',
                       LIST_FAIL='0', OFF_FAIL='0', SWAP_SIZE='2G',
                       SWAP_RAM_THRESHOLD_MB='2048', FAILURE=failure)
            result = subprocess.run([bash], input=script, text=True, encoding='utf-8',
                                    capture_output=True, env=env, timeout=15)
            contents = [(root / name).read_text(encoding='utf-8').replace(posix, '')
                        for name in ('calls', 'fstab', 'active')]
            return result, *contents

    def assert_persistence_failure(self, result, calls, fstab, active):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('ERROR:Не удалось записать', result.stderr)
        self.assertIn('может быть активен в текущей сессии', result.stderr)
        self.assertIn('автоподключение после перезагрузки не настроено', result.stderr)
        self.assertNotIn('OK:', result.stdout)
        self.assertNotIn('создан и активирован', result.stdout)
        self.assertIn('/swapfile 2147479552 file\n', active)
        self.assertEqual(calls.count('swapon /swapfile\n'), 1)
        self.assertNotIn('swapoff', calls)
        self.assertNotIn('rm ', calls)
        self.assertEqual(fstab, FSTAB)

    def test_append_write_failure_after_activation(self):
        for errexit in (False, True):
            with self.subTest(errexit=errexit):
                self.assert_persistence_failure(*self.run_swap('write', errexit=errexit))

    def test_append_redirection_failure_after_activation(self):
        self.assert_persistence_failure(*self.run_swap('redirect'))

    def test_successful_append_preserves_happy_path(self):
        result, calls, fstab, active = self.run_swap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count('APPEND\n'), 1)
        self.assertEqual(fstab, FSTAB + '/swapfile none swap sw 0 0\n')
        self.assertIn('/swapfile 2147479552 file\n', active)
        self.assertEqual(result.stdout.count('OK:Swap 2G создан и активирован'), 1)

    def test_existing_matching_swap_and_correct_entry_no_append(self):
        before = FSTAB + '/swapfile none swap sw 0 0\n'
        result, calls, after, _ = self.run_swap(
            'write', active='/swapfile 2147479552 file\n', fstab=before, repeat=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, '')
        self.assertEqual(after, before)
        self.assertEqual(result.stdout.count('OK:'), 2)

    def test_foreign_swap_default_no_preserves_runtime_and_fstab(self):
        foreign = '/dev/zram0 1048576 partition\n'
        result, calls, after, active = self.run_swap('write', active=foreign)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, '')
        self.assertEqual(after, FSTAB)
        self.assertEqual(active, foreign)

    def test_foreign_swap_preserved_when_explicit_add_cannot_persist(self):
        foreign = '/dev/zram0 1048576 partition\n'
        outcome = self.run_swap('write', active=foreign, answer='y')
        self.assert_persistence_failure(*outcome)
        self.assertTrue(outcome[3].startswith(foreign))

    def test_real_part2_propagates_both_persistence_failures(self):
        for failure in ('write', 'redirect'):
            with self.subTest(failure=failure):
                outcome = self.run_swap(failure, outer=True)
                self.assert_persistence_failure(*outcome)
                result = outcome[0]
                self.assertNotIn('Часть 2 завершена', result.stdout + result.stderr)
                self.assertEqual([line[5:] for line in result.stdout.splitlines()
                                  if line.startswith('STEP:')], STEPS[:STEPS.index('configure_swap')])

    def test_successful_repeat_is_idempotent(self):
        result, calls, after, active = self.run_swap(repeat=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count('APPEND\n'), 1)
        self.assertEqual(calls.count('fallocate '), 1)
        self.assertEqual(calls.count('swapon /swapfile\n'), 1)
        self.assertNotIn('swapoff', calls)
        self.assertEqual(after, FSTAB + '/swapfile none swap sw 0 0\n')
        self.assertEqual(active, '/swapfile 2147479552 file\n')


if __name__ == '__main__':
    unittest.main()
