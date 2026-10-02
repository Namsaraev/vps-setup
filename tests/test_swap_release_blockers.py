"""F18/F19: real temporary files, injected runtime failures, never real swapon.

SWAP_AUDIT_SOURCE selects an exact-base source for before-fix reproductions.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from atomic_support import HELPER
from test_part2_error_propagation import PART2, STEPS

SOURCE = Path(os.environ.get('SWAP_AUDIT_SOURCE',
              Path(__file__).resolve().parents[1] / 'tunevps.sh')).read_text()
FUNCTION = HELPER + '\nconfigure_swap() {' + SOURCE.split('configure_swap() {', 1)[1].split(
    '\n# Безопасное управление ключами pin', 1)[0]
PRELUDE = r'''
set -euo pipefail
section() { :; }
info() { echo "$*"; }
warn() { echo "$*"; }
ok() { echo "OK:$*"; }
error() { echo "$*" >&2; }
ask() { echo PROMPT; printf -v "$2" %s "$ANSWER"; }
free() { echo 'Mem: 1024 0 0'; }
getconf() { echo "$PAGE"; [ "$FAILURE" != page ]; }
log() { echo "$*" >> "$ROOT/calls"; }
swapon() {
  if [[ "$1" == --show=* ]]; then
    # Command substitutions run in subshells: the count is deliberately on disk.
    local n=$(cat "$ROOT/reads")
    n=$((n+1)); echo "$n" > "$ROOT/reads"
    if [[ "$FAILURE" == probe && "$n" -ge 3 ]]; then
      cat "$ROOT/active"; return 23
    fi
    cat "$ROOT/active"; return 0
  fi
  log "swapon $*"
  local old=false bytes
  [[ "$(head -c 8 "$1")" != OLD-SWAP ]] || old=true
  if [[ "$old" == true ]]; then
    [[ "$FAILURE" != restore_on ]] || return 23
    bytes="$OLD_BYTES"
  else
    [[ "$FAILURE" != on && "$FAILURE" != restore_on && "$FAILURE" != restore_move ]] || return 23
    bytes=$(( $(stat -c %s "$1") / PAGE * PAGE - PAGE ))
    [[ "$FAILURE" != wrong ]] || bytes=$((bytes-PAGE))
  fi
  printf '%s %s file\n' "$1" "$bytes" >> "$ROOT/active"
  [[ "$old" == true || "$FAILURE" != partial_on ]] || return 23
}
swapoff() {
  log "swapoff $*"
  [[ "$FAILURE" != off ]] || return 23
  if [[ "$FAILURE" == recovery_off && -e "$ROOT/new-on" ]]; then return 23; fi
  awk -v name="$1" '$1 != name' "$ROOT/active" > "$ROOT/next"
  command mv "$ROOT/next" "$ROOT/active"
  [[ "$FAILURE" != partial_off ]] || return 23
}
fallocate() {
  log "fallocate $*"
  if [[ "$FAILURE" == alloc || "$FAILURE" == dd ]]; then
    echo partial > "${@: -1}"; return 23
  fi
  if [[ "$REAL_TOOLS" == 1 ]]; then command fallocate "$@"; else
    truncate -s "$2" "${@: -1}"
  fi
}
dd() {
  log "dd $*"
  [[ "$FAILURE" != dd ]] || return 23
  if [[ "$REAL_TOOLS" == 1 ]]; then command dd "$@"; else
    local arg output count bytes=0 block=1
    for arg in "$@"; do
      case "$arg" in of=*) output=${arg#of=};; count=*) count=${arg#count=};;
        bs=1M) block=1048576;; iflag=count_bytes) bytes=1;; esac
    done
    [[ "$bytes" == 1 ]] || count=$((count*block))
    truncate -s "$count" "$output"
  fi
}
chmod() { log "chmod $*"; [[ "$FAILURE" != chmod ]] && command chmod "$@"; }
mkswap() {
  log "mkswap $*"
  [[ "$FAILURE" != format ]] || return 23
  [[ "$REAL_TOOLS" != 1 ]] || command mkswap "$@"
}
mv() {
  log "mv $*"
  if [[ "$FAILURE" == move && "$*" == *swapfile.new.* ]]; then return 23; fi
  if [[ "$FAILURE" == restore_move && "$*" == *swapfile.old.* && "${@: -1}" == "$ROOT/swapfile" ]]; then return 23; fi
  command mv "$@"
}
rm() {
  log "rm $*"
  if [[ "$FAILURE" == cleanup && "$*" == *swapfile.old.* ]]; then return 23; fi
  command rm "$@"
}
'''


@unittest.skipUnless(sys.platform.startswith('linux'), 'swap filesystem semantics require Linux')
class SwapReleaseTest(unittest.TestCase):
    def run_swap(self, failure='', size='2G', old=True, active=None, answer='y',
                 repeat=False, outer=False, page='4096', real=False, setup='', repair=False):
        with tempfile.TemporaryDirectory(prefix='swap-release-') as tmp:
            root = Path(tmp)
            own = str(root / 'swapfile')
            old_data = b'OLD-SWAP\noriginal bytes\x00'
            if old:
                (root / 'swapfile').write_bytes(old_data)
            if active is None:
                active = '/dev/zram0 1048576 partition\n'
                if old:
                    active += '/swapfile 1044480 file\n'
            (root / 'active').write_text(active.replace('/swapfile', own))
            fstab = '# foreign\n/dev/zram0 none swap sw 0 0\n/swapfile none swap defaults 0 0\n'
            (root / 'fstab').write_text(fstab.replace('/swapfile', own))
            (root / 'calls').touch()
            (root / 'reads').write_text('0')
            function = FUNCTION.replace('/etc/fstab', str(root / 'fstab')).replace('/swapfile', own)
            stubs = '\n'.join(f'{name}() {{ echo STEP:{name}; }}'
                              for name in STEPS if name != 'configure_swap')
            call = 'part2_setup' if outer else 'configure_swap'
            script = PRELUDE + function + '\n' + stubs + '\n' + PART2 + '\n' + setup
            if repair:
                script += '\nconfigure_swap && exit 91\nATOMIC_FAILURE=\nconfigure_swap || exit $?\n'
            else:
                script += f'\n{call} || exit $?\n' * (2 if repeat else 1)
            env = dict(os.environ, ROOT=tmp, ANSWER=answer, FAILURE=failure,
                       SWAP_SIZE=size, SWAP_RAM_THRESHOLD_MB='2048', PAGE=page,
                       OLD_BYTES='1044480', REAL_TOOLS=str(int(real)),
                       ATOMIC_FAILURE='write' if failure == 'persist' else '')
            r = subprocess.run(['/bin/bash'], input=script, text=True,
                               capture_output=True, env=env, timeout=25)
            files = {p.name: p.read_bytes() for p in root.iterdir() if p.is_file()
                     and (p.name.startswith('swapfile') and p.stat().st_size < 1048576)}
            after_size = (root / 'swapfile').stat().st_size if (root / 'swapfile').exists() else None
            calls = (root / 'calls').read_text().replace(tmp, '')
            state = (root / 'active').read_text().replace(tmp, '')
            after = (root / 'fstab').read_text().replace(tmp, '')
            if '/dev/zram0' in active:
                self.assertIn('/dev/zram0 1048576 partition', state)
            self.assertNotIn('swapoff /dev/', calls)
            return r, calls, state, after, files, after_size

    def assert_restored(self, outcome):
        r, calls, active, fstab, files, _ = outcome
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertEqual(files.get('swapfile'), b'OLD-SWAP\noriginal bytes\x00')
        self.assertIn('/swapfile 1044480 file\n', active)
        self.assertIn('/swapfile none swap defaults 0 0', fstab)
        self.assertNotIn('OK:', r.stdout)
        self.assertFalse(any('.old.' in f or '.new.' in f for f in files), files)

    def test_f18_prepare_failure_preserves_old_file_and_runtime(self):
        for failure in ('dd', 'chmod', 'format'):
            with self.subTest(failure=failure):
                outcome = self.run_swap(failure)
                self.assert_restored(outcome)
                self.assertNotIn('swapoff ', outcome[1])

    def test_f18_activation_and_install_failures_restore_old(self):
        for failure in ('on', 'partial_on', 'move', 'wrong'):
            with self.subTest(failure=failure):
                self.assert_restored(self.run_swap(failure))

    def test_swapoff_failure_and_partial_failure_restore(self):
        for failure in ('off', 'partial_off'):
            with self.subTest(failure=failure):
                self.assert_restored(self.run_swap(failure))

    def test_failed_runtime_probe_keeps_both_resources(self):
        r, calls, active, _, files, _ = self.run_swap('probe')
        self.assertEqual(r.returncode, 1)
        self.assertIn('FATAL:', r.stderr)
        self.assertTrue(any('.old.' in f and files[f].startswith(b'OLD-SWAP') for f in files))
        self.assertIn('/swapfile 2147479552 file', active)
        self.assertNotIn('rm -f -- /swapfile\n', calls)

    def test_recovery_activation_failure_keeps_old_bytes(self):
        r, _, active, _, files, _ = self.run_swap('restore_on')
        self.assertEqual(r.returncode, 1)
        self.assertIn('FATAL:', r.stderr)
        self.assertEqual(files['swapfile'], b'OLD-SWAP\noriginal bytes\x00')
        self.assertNotIn('/swapfile ', active)

    def test_recovery_rename_failure_names_preserved_backup(self):
        r, _, _, _, files, _ = self.run_swap('restore_move')
        self.assertEqual(r.returncode, 1)
        self.assertIn('FATAL:', r.stderr)
        self.assertIn('.old.', r.stderr)
        self.assertTrue(any('.old.' in f and files[f].startswith(b'OLD-SWAP') for f in files))

    def test_partial_new_activation_swapoff_failure_keeps_active_file(self):
        setup = r'''
eval "$(declare -f swapon | sed '1s/swapon/original_swapon/')"
swapon() {
  original_swapon "$@" || return $?
  if [[ "$1" != --show=* ]]; then touch "$ROOT/new-on"; return 23; fi
}
'''
        r, calls, active, _, files, _ = self.run_swap('recovery_off', setup=setup)
        self.assertEqual(r.returncode, 1)
        self.assertIn('FATAL:', r.stderr)
        self.assertIn('/swapfile 2147479552 file', active)
        self.assertTrue(any('.old.' in f for f in files))
        self.assertNotIn('rm -f -- /swapfile\n', calls)

    def test_inactive_old_file_is_restored_without_activation(self):
        r, calls, active, _, files, _ = self.run_swap('on', active='/dev/zram0 1048576 partition\n')
        self.assertEqual(r.returncode, 1)
        self.assertEqual(files['swapfile'], b'OLD-SWAP\noriginal bytes\x00')
        self.assertNotIn('/swapfile ', active)
        self.assertEqual(calls.count('swapon /swapfile\n'), 1)

    def test_creation_activation_failure_leaves_no_owned_swap(self):
        r, _, active, _, files, _ = self.run_swap('on', old=False)
        self.assertEqual(r.returncode, 1)
        self.assertNotIn('/swapfile ', active)
        self.assertNotIn('swapfile', files)

    def test_persistence_failure_keeps_verified_runtime_and_propagates(self):
        r, _, active, fstab, _, size = self.run_swap('persist', outer=True)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(size, 2147483648)
        self.assertIn('/swapfile 2147479552 file', active)
        self.assertIn('/swapfile none swap defaults 0 0', fstab)
        self.assertNotIn('Часть 2 завершена', r.stdout)
        self.assertNotIn('OK:', r.stdout)

    def test_runtime_failure_stops_real_part2(self):
        r, _, _, _, _, _ = self.run_swap('on', outer=True)
        self.assertEqual(r.returncode, 1)
        self.assertNotIn('STEP:configure_pin', r.stdout)
        self.assertNotIn('Часть 2 завершена', r.stdout)

    def test_persistence_failure_is_repaired_on_next_run_without_replacement(self):
        r, calls, active, fstab, _, _ = self.run_swap('persist', repair=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(calls.count('swapon /swapfile\n'), 1)
        self.assertEqual(calls.count('swapoff /swapfile\n'), 1)
        self.assertEqual(r.stdout.count('PROMPT'), 1)
        self.assertIn('/swapfile 2147479552 file', active)
        self.assertIn('/swapfile none swap sw 0 0', fstab)

    def test_cleanup_failure_keeps_valid_runtime_and_names_backup(self):
        r, _, active, fstab, files, _ = self.run_swap('cleanup')
        self.assertEqual(r.returncode, 1)
        self.assertIn('.old.', r.stderr)
        self.assertIn('/swapfile 2147479552 file', active)
        self.assertIn('/swapfile none swap defaults 0 0', fstab)
        self.assertTrue(any('.old.' in f and files[f].startswith(b'OLD-SWAP') for f in files))

    def test_wrong_staged_length_leaves_old_swap_running(self):
        r, calls, _, _, _, _ = outcome = self.run_swap(setup='stat() { echo 1; }\n')
        self.assert_restored(outcome)
        self.assertNotIn('swapoff ', calls)

    def test_backup_reservation_failure_leaves_old_swap_running(self):
        setup = r'''
mktemp() { [[ "$1" != *swapfile.old.* ]] && command mktemp "$@"; }
'''
        outcome = self.run_swap(setup=setup)
        self.assert_restored(outcome)
        self.assertNotIn('swapoff ', outcome[1])

    def test_successful_replacement_prepares_before_swapoff_and_repeats(self):
        r, calls, active, fstab, files, size = self.run_swap(repeat=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertLess(calls.index('mkswap '), calls.index('swapoff '))
        self.assertEqual(calls.count('fallocate '), 1)
        self.assertEqual(calls.count('swapoff '), 1)
        self.assertEqual(size, 2147483648)
        self.assertIn('/swapfile 2147479552 file', active)
        self.assertIn('/swapfile none swap sw 0 0', fstab)
        self.assertFalse(any('.old.' in f or '.new.' in f for f in files))

    def test_f19_decimal_binary_and_byte_sizes_repeat_without_prompt(self):
        for size, wanted in [('2G', 2147483648), ('2GiB', 2147483648), ('2GB', 2000000000),
                             ('1537K', 1573888), ('65537', 65537), ('64Ki', 65536)]:
            for failure in ('', 'alloc'):
                with self.subTest(size=size, fallback=bool(failure)):
                    r, calls, active, _, _, actual = self.run_swap(failure, size=size, repeat=True)
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertEqual(actual, wanted)
                    self.assertIn(f'/swapfile {wanted//4096*4096-4096} file', active)
                    self.assertEqual(r.stdout.count('PROMPT'), 1)
                    if failure:
                        self.assertIn(f'count={wanted} iflag=count_bytes', calls)

    def test_f19_overflow_and_too_small_rejected_before_mutation(self):
        for size in ('8192P', '9223372036854775808', '18446744073709551617',
                     '999999999999999999999999999G', '1', '4K', '8191', '0G', '-2G', '2g'):
            with self.subTest(size=size):
                r, calls, _, _, files, _ = self.run_swap(size=size)
                self.assertEqual(r.returncode, 1)
                self.assertEqual(calls, '')
                self.assertEqual(files['swapfile'], b'OLD-SWAP\noriginal bytes\x00')

    def test_page_size_failure_has_no_mutation(self):
        for failure, page in [('page', '4096'), ('', '0'), ('', 'bad')]:
            r, calls, _, _, _, _ = self.run_swap(failure, page=page)
            self.assertEqual(r.returncode, 1)
            self.assertEqual(calls, '')

    def test_64k_page_size_and_partial_final_page(self):
        r, _, active, _, _, size = self.run_swap(size='200001', page='65536', repeat=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(size, 200001)
        self.assertIn('/swapfile 131072 file', active)

    def test_malformed_duplicate_or_nonfile_owned_runtime_refused(self):
        for active in ('/swapfile 0 file\n', '/swapfile 1044480 partition\n',
                       '/swapfile 1044480 file\n/swapfile 1044480 file\n',
                       '/swapfile 9223372036854775808 file\n', '/swapfile bad file\n',
                       '/swapfile 1044480 file extra\n'):
            with self.subTest(active=active):
                r, calls, _, _, _, _ = self.run_swap(active=active)
                self.assertEqual(r.returncode, 1)
                self.assertEqual(calls, '')

    def test_real_fallocate_dd_mkswap_small_non_mib_files(self):
        for failure in ('', 'alloc'):
            r, _, active, _, _, size = self.run_swap(failure, size='65537', real=True, repeat=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(size, 65537)
            self.assertIn('/swapfile 61440 file', active)

    def test_f19_checked_parser_all_units_and_signed_boundary(self):
        parser = 'swap_size_to_bytes() {' + SOURCE.split('swap_size_to_bytes() {', 1)[1].split(
            '\n  desired_bytes=', 1)[0]
        for suffix, exponent in [('', 0), ('K', 1), ('M', 2), ('G', 3), ('T', 4), ('P', 5)]:
            for tail, radix in ([('', 1)] if not suffix else [('', 1024), ('i', 1024),
                                                               ('iB', 1024), ('B', 1000)]):
                value = '2' + suffix + tail
                with self.subTest(value=value):
                    r = subprocess.run(['/bin/bash', '-c', parser + '\nswap_size_to_bytes "$1"',
                                        '_', value], capture_output=True, text=True)
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertEqual(int(r.stdout), 2 * radix ** exponent)
        for value, valid in [('9223372036854775807', True), ('8191P', True),
                             ('9223372036854775808', False), ('8192P', False)]:
            with self.subTest(value=value):
                r = subprocess.run(['/bin/bash', '-c', parser + '\nswap_size_to_bytes "$1"',
                                    '_', value], capture_output=True, text=True)
                self.assertEqual(r.returncode == 0, valid)

    def test_f19_one_page_away_from_expected_is_not_matching(self):
        for bytes_ in (2147475456, 2147483648):
            r, calls, _, _, _, _ = self.run_swap(
                active=f'/swapfile {bytes_} file\n', answer='n')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('PROMPT', r.stdout)
            self.assertEqual(calls, '')


if __name__ == '__main__':
    unittest.main()
