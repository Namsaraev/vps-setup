"""Run only configure_swap with sandbox paths and mocked system commands."""
import os
from atomic_support import HELPER
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'tunevps.sh').read_text(encoding='utf-8')
FUNCTION = 'configure_swap() {' + SOURCE.split('configure_swap() {', 1)[1].split('\n# Безопасное управление ключами pin', 1)[0]
PRELUDE = r'''
set -euo pipefail
section() { :; }
info() { echo "$*"; }
ok() { echo "$*"; }
warn() { echo "$*"; }
error() { echo "$*" >&2; }
ask() { echo "PROMPT: $1"; printf -v "$2" '%s' "$ANSWER"; }
free() { echo "Mem: $RAM 0 0"; }
getconf() { echo 4096; }
swapon() {
  if [[ "$1" == --show=* ]]; then
    [ "$LIST_FAIL" = 0 ] || return 1
    cat "$ROOT/active"
  else
    echo "swapon $*" >> "$ROOT/calls"
    printf '%s 2147479552 file\n' "$1" >> "$ROOT/active"
  fi
}
swapoff() {
  echo "swapoff $*" >> "$ROOT/calls"
  [ "$OFF_FAIL" = 0 ] || return 1
  awk -v name="$1" '$1 != name' "$ROOT/active" > "$ROOT/next"
  command mv "$ROOT/next" "$ROOT/active"
}
rm() { echo "rm $*" >> "$ROOT/calls"; command rm "$@"; }
fallocate() { echo "fallocate $*" >> "$ROOT/calls"; touch "${@: -1}"; }
dd() { echo 'unexpected dd' >&2; return 1; }
chmod() { echo "chmod $*" >> "$ROOT/calls"; }
mkswap() { echo "mkswap $*" >> "$ROOT/calls"; }
'''
FSTAB = ('# foreign swap configuration\n/dev/sda2 none swap sw 0 0\n'
         '/dev/zram0 none swap defaults 0 0\n/other.swap none swap sw 0 0\n'
         '/swapfile.backup none swap sw 0 0\n# keep /swapfile in a comment\n')


FUNCTION = HELPER + "\n" + FUNCTION


class SwapTest(unittest.TestCase):
    def run_swap(self, active='', answer='', ram='1024', fstab=FSTAB,
                 repeat=False, list_fail='0', off_fail='0', symlink=False, extra_setup=''):
        with tempfile.TemporaryDirectory(prefix='swap-policy-') as tmp:
            root = Path(tmp)
            # cygpath also works with Git Bash; paths stay inside this temporary directory.
            bash = os.environ.get('BASH', 'bash')
            posix = subprocess.check_output([bash, '-c', 'cygpath -u "$1" 2>/dev/null || printf "%s" "$1"', '_', root.as_posix()], text=True).strip()
            own = posix + '/swapfile'
            (root / 'active').write_text(active.replace('/swapfile', own))
            (root / 'fstab').write_text(fstab.replace('/swapfile', own))
            (root / 'calls').touch()
            (root / 'foreign').write_text('preserve me')
            if '/swapfile ' in active:
                (root / 'swapfile').touch()
            function = FUNCTION.replace('/etc/fstab', posix + '/fstab').replace('/swapfile', own)
            setup = 'ln -s "$ROOT/foreign" "$ROOT/swapfile"\n' if symlink else ''
            env = dict(os.environ, ROOT=posix, ANSWER=answer, RAM=ram,
                       LIST_FAIL=list_fail, OFF_FAIL=off_fail,
                       SWAP_SIZE='2G', SWAP_RAM_THRESHOLD_MB='2048')
            result = subprocess.run([bash], input=PRELUDE + function + '\n' + setup + extra_setup + '\n' +
                                    'configure_swap\n' * (2 if repeat else 1),
                                    text=True, encoding='utf-8', capture_output=True, env=env, timeout=15)
            calls = (root / 'calls').read_text().replace(posix, '')
            after = (root / 'fstab').read_text().replace(posix, '')
            self.assertEqual((root / 'foreign').read_text(), 'preserve me')
            foreign_before = [line for line in active.splitlines() if not line.startswith('/swapfile ')]
            foreign_after = [line for line in (root / 'active').read_text().splitlines()
                             if not line.startswith(own + ' ')]
            self.assertEqual(foreign_after, foreign_before)
            return result, calls, after

    def test_no_swap_low_ram_create_and_repeat(self):
        result, calls, fstab = self.run_swap(repeat=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count('fallocate '), 1)
        self.assertNotIn('swapoff', calls)
        self.assertEqual(fstab, FSTAB + '/swapfile none swap sw 0 0\n')

    def test_matching_noop(self):
        for size in (2147483648, 2147479552):
            result, calls, fstab = self.run_swap(f'/swapfile {size} file\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls, '')
            self.assertNotIn('PROMPT', result.stdout)
            self.assertEqual(fstab, FSTAB + '/swapfile none swap sw 0 0\n')

    def test_mismatch_replace_only_owned_and_fstab(self):
        for foreign in ('', '/dev/sda2 1073741824 partition\n/dev/zram0 536870912 partition\n/other.swap 1048576 file\n'):
            before = FSTAB + '  /swapfile none swap defaults 0 0\n/swapfile none swap sw 0 0\n'
            result, calls, after = self.run_swap(foreign + '/swapfile 1073741824 file\n', 'y', fstab=before, repeat=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls.count('swapoff /swapfile\n'), 1)
            self.assertEqual(calls.count('fallocate '), 1)
            self.assertNotIn('/dev/', calls)
            self.assertNotIn('/other.swap', calls)
            self.assertEqual(after, FSTAB + '/swapfile none swap sw 0 0\n')

    def test_foreign_only_default_preserve(self):
        for source in ('/dev/sda2', '/dev/zram0', '/dev/mapper/swap', '/other.swap'):
            result, calls, after = self.run_swap(f'{source} 1073741824 partition\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(source, result.stdout)
            self.assertIn('Дополнительно', result.stdout)
            self.assertEqual(calls, '')
            self.assertEqual(after, FSTAB)

    def test_foreign_explicit_add(self):
        result, calls, _ = self.run_swap('/dev/zram0 1048576 partition\n', 'y')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('fallocate ', calls)
        self.assertNotIn('swapoff', calls)

    def test_foreign_plus_matching_noop(self):
        result, calls, _ = self.run_swap('/dev/zram0 1048576 partition\n/swapfile 2147479552 file\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, '')
        self.assertIn('/dev/zram0', result.stdout)
        self.assertNotIn('PROMPT', result.stdout)

    def test_decline_replacement(self):
        result, calls, _ = self.run_swap('/swapfile 1073741824 file\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, '')

    def test_high_ram_noop(self):
        result, calls, _ = self.run_swap(ram='4096')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, '')

    def test_listing_failure_no_changes(self):
        result, calls, after = self.run_swap(list_fail='1')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, '')
        self.assertEqual(after, FSTAB)

    def test_swapoff_failure_stops(self):
        result, calls, after = self.run_swap('/swapfile 1073741824 file\n', 'y', off_fail='1')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, 'swapoff /swapfile\n')
        self.assertEqual(after, FSTAB)

    @unittest.skipIf(os.name == 'nt', 'Git Bash ln may copy files instead of creating symlinks')
    def test_symlink_refused(self):
        result, calls, after = self.run_swap(symlink=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, '')
        self.assertEqual(after, FSTAB)


if __name__ == '__main__':
    unittest.main()
