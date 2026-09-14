"""Extract the real function; all kernel commands are stubs, all writes temporary."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_part2_error_propagation import PART2, STEPS

SOURCE = (Path(__file__).resolve().parents[1] / 'tunevps.sh').read_text(encoding='utf-8')
FUNCTION = 'configure_safe_sysctl() {' + SOURCE.split('configure_safe_sysctl() {', 1)[1].split('\n# Глобальный лимит', 1)[0]
SUCCESS = 'Безопасные sysctl применены'
BASE = '''# Совместимо с VPN, policy routing, туннелями и proxy.
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
{bbr}
fs.file-max = 1048576
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
'''
BBR = 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr'
FAILURES = ['modprobe', 'missing-modprobe', 'remove'] + [f'{kind}-{area}' for area in ('modules', 'sysctl', 'limits') for kind in ('mkdir', 'open', 'write', 'partial')] + ['apply']


class ConfigureSafeSysctlTest(unittest.TestCase):
    def run_setup(self, failure='', mode='module', part2=False, repeat=False, errexit=False):
        with tempfile.TemporaryDirectory(prefix='sysctl test ') as tmp:
            root = Path(tmp)
            targets = {'modules': root / 'modules-load.d/tcp_bbr.conf',
                       'sysctl': root / 'sysctl.d/99-vps-tuning.conf',
                       'limits': root / 'security/limits.d/99-vps.conf'}
            # Start with absent directories except where an open failure needs a directory target.
            if failure.startswith('open-'):
                targets[failure[5:]].mkdir(parents=True)
            neighbor = root / 'unrelated.conf'
            neighbor.write_text('untouched\n')
            stamp = neighbor.stat().st_mtime_ns
            if mode == 'unavailable' or failure == 'remove':
                targets['modules'].parent.mkdir(exist_ok=True)
                targets['modules'].write_text('tcp_bbr\n')
            prelude = r'''
set -o pipefail
section() { :; }
info() { :; }
ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; }
error() { echo "ERROR: $*" >&2; }
command() {
  if [ "$*" = '-v modprobe' ] && [ "$FAILURE" = missing-modprobe ]; then return 1; fi
  builtin command "$@"
}
modinfo() { [ "$MODE" = module ] && [ "$FAILURE" != remove ]; }
modprobe() {
  echo modprobe >> "$ROOT/calls"
  [ "$*" = tcp_bbr ] || return 98
  [ "$FAILURE" != modprobe ] || return 23
  LOADED=true
}
sysctl() {
  case "$*" in
    '-n net.ipv4.tcp_available_congestion_control')
      if [ "$MODE" = builtin ] || [ "${LOADED:-false}" = true ]; then echo 'reno cubic bbr'; else echo 'reno cubic'; fi ;;
    --system)
      echo apply >> "$ROOT/calls"
      [ -s "$ROOT/sysctl.d/99-vps-tuning.conf" ] || return 97
      [ "$FAILURE" != apply ] || return 23 ;;
    *) return 98 ;;
  esac
}
mkdir() {
  case "$*" in
    *modules-load.d*) AREA=modules ;;
    *sysctl.d*) AREA=sysctl ;;
    *limits.d*) AREA=limits ;;
    *) return 98 ;;
  esac
  [ "$FAILURE" != "mkdir-$AREA" ] || return 23
  builtin command mkdir "$@"
}
printf() {
  if [ "$AREA" = modules ]; then
    [ "$FAILURE" != write-modules ] || return 23
    if [ "$FAILURE" = partial-modules ]; then builtin printf tcp_; return 23; fi
  fi
  builtin printf "$@"
}
cat() {
  [ "$FAILURE" != "write-$AREA" ] || return 23
  if [ "$FAILURE" = "partial-$AREA" ]; then builtin printf 'partial\n'; return 23; fi
  builtin command cat "$@"
}
rm() {
  [ "$FAILURE" != remove ] || return 23
  builtin command rm "$@"
}
'''
            prelude += '\n'.join(f'{step}() {{ echo STEP:{step}; }}' for step in STEPS if step != 'configure_safe_sysctl')
            function = FUNCTION.replace('/etc/', '"$ROOT"/')
            self.assertNotIn('/etc/', function)
            call = 'part2_setup' if part2 else 'configure_safe_sysctl'
            script = prelude + '\n' + function + '\n' + PART2 + '\n'
            script += 'set -e\n' if errexit else ''
            script += f'{call} || exit $?\n'
            if repeat:
                script += 'builtin command cp "$ROOT/sysctl.d/99-vps-tuning.conf" "$ROOT/first"\n'
                script += f'{call} || exit $?\n'
            result = subprocess.run([os.environ.get('BASH', 'bash')], input=script,
                                    env=dict(os.environ, ROOT=root.as_posix(), MODE=mode, FAILURE=failure),
                                    text=True, encoding='utf-8', capture_output=True, timeout=10)
            configs = {k: p.read_text(encoding='utf-8') if p.is_file() else None for k, p in targets.items()}
            calls = (root / 'calls').read_text(encoding='utf-8').splitlines() if (root / 'calls').exists() else []
            self.assertEqual(neighbor.read_text(encoding='utf-8'), 'untouched\n')
            self.assertEqual(neighbor.stat().st_mtime_ns, stamp)
            if repeat:
                self.assertEqual((root / 'first').read_text(encoding='utf-8'), configs['sysctl'])
            return result, configs, calls

    def check_failure(self, failure, part2=False):
        for errexit in (False, True):
            with self.subTest(failure=failure, part2=part2, errexit=errexit):
                result, configs, calls = self.run_setup(failure=failure, part2=part2, errexit=errexit)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('ERROR:', result.stderr)
                self.assertNotIn(SUCCESS, result.stdout + result.stderr)
                self.assertNotIn('Часть 2 завершена', result.stdout + result.stderr)
                self.assertEqual(calls.count('apply'), int(failure == 'apply' or failure.endswith('-limits')))
                if failure.startswith('partial-'):
                    area = failure[8:]
                    self.assertEqual(configs[area], 'tcp_' if area == 'modules' else 'partial\n')
                if part2:
                    self.assertEqual([s for s in result.stdout.splitlines() if s.startswith('STEP:')],
                                     [f'STEP:{s}' for s in STEPS[:STEPS.index('configure_safe_sysctl')]])

    def test_critical_failures(self):
        for failure in FAILURES:
            self.check_failure(failure)

    def test_failures_propagate_through_part2(self):
        for failure in FAILURES:
            self.check_failure(failure, part2=True)

    def test_success_modes_and_idempotence(self):
        for mode in ('unavailable', 'module', 'builtin'):
            for repeat in (False, True):
                with self.subTest(mode=mode, repeat=repeat):
                    result, configs, calls = self.run_setup(mode=mode, repeat=repeat, errexit=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(configs['sysctl'], BASE.format(bbr='' if mode == 'unavailable' else BBR))
                    self.assertEqual(configs['modules'], 'tcp_bbr\n' if mode == 'module' else None)
                    self.assertEqual(configs['limits'], '* soft nofile 524288\n* hard nofile 1048576\nroot soft nofile 524288\nroot hard nofile 1048576\n')
                    self.assertEqual(calls.count('apply'), 1 + repeat)
                    self.assertEqual(calls.count('modprobe'), int(mode == 'module'))
                    self.assertEqual(result.stdout.count(SUCCESS), 1 + repeat)

    def test_part2_success(self):
        result, _, _ = self.run_setup(part2=True, errexit=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count('Часть 2 завершена'), 1)


if __name__ == '__main__':
    unittest.main()
