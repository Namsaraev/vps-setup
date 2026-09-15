"""Run real UFW functions with shell stubs; never invoke the system firewall."""
import os
from pathlib import Path
import subprocess
import unittest

from test_part2_error_propagation import PART2, STEPS

SOURCE = (Path(__file__).resolve().parents[1] / 'tunevps.sh').read_text(encoding='utf-8')
FUNCTIONS = 'ufw_is_active() {' + SOURCE.split('ufw_is_active() {', 1)[1].split('\nset_sshd_line()', 1)[0]
COMMANDS = ['default deny incoming', 'default allow outgoing',
            'allow 5829/tcp comment SSH', 'allow 80/tcp comment HTTP',
            'allow 443/tcp comment HTTPS', '--force enable']
SUCCESS = 'UFW включён: SSH 5829, HTTP/HTTPS'


class ConfigureUfwTest(unittest.TestCase):
    def run_ufw(self, active=False, failure='', refuse=False, missing_rule=False,
                part2=False, errexit=False, action='', ask_failure='',
                source_ip='192.0.2.1', call_override='', status_failure_at=0,
                pipefail=True, repeat=False, missing_ufw=False, read_error=False):
        prelude = '''
set -o pipefail
SSH_PORT=5829
section() { :; }
info() { echo "INFO: $*"; }
ok() { echo "OK: $*"; }
error() { echo "ERROR: $*" >&2; }
warn() { echo "WARN: $*"; }
ask() {
  if [[ "$2" == "$ASK_FAILURE" ]]; then
    if [[ "$READ_ERROR" == yes ]]; then
      read -r "$2" <&-  # Closed input descriptor, distinct from EOF.
      return $?
    fi
    # Real read on an exhausted input: failure must not become a default.
    read -r "$2" < /dev/null
    return $?
  fi
  case "$2" in
    answer) printf -v answer '%s' "$ANSWER" ;;
    action) printf -v action '%s' "$ACTION" ;;
    source_ip) printf -v source_ip '%s' "$SOURCE_IP" ;;
  esac
}
yes_by_default() { [[ "$1" != n ]]; }
ufw() {
  echo "CMD:$*" >&2
  if [[ "$*" == "$FAILURE" ]]; then return 23; fi
  if [[ "$1" == status ]]; then
    local count=0
    if [[ -f "$STATUS_COUNT" ]]; then read -r count < "$STATUS_COUNT"; fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$STATUS_COUNT"
    echo "Status: $STATE"
    if [[ "$MISSING_RULE" == no ]]; then echo '5829/tcp ALLOW Anywhere'; fi
    if [[ "$count" == "$STATUS_FAILURE_AT" ]]; then return 23; fi
    return 0
  fi
  return 0
}
'''
        env = dict(os.environ, STATE='active' if active else 'inactive', FAILURE=failure,
                   ANSWER='n' if refuse else '', MISSING_RULE='yes' if missing_rule else 'no',
                   ACTION=action, ASK_FAILURE=ask_failure, SOURCE_IP=source_ip,
                   STATUS_FAILURE_AT=str(status_failure_at), READ_ERROR='yes' if read_error else 'no')
        stubs = '\n'.join(f'{name}() {{ echo STEP:{name}; }}' for name in STEPS if name != 'configure_ufw')
        call = call_override or ('part2_setup' if part2 else 'configure_ufw')
        prelude += '\nSTATUS_COUNT=$(mktemp)\ntrap \'rm -f "$STATUS_COUNT"\' EXIT\n'
        if not pipefail:
            prelude += 'set +o pipefail\n'
        if missing_ufw:
            prelude += 'command() { return 1; }\n'
        if repeat:
            call += ' || exit $?\n' + call
        return subprocess.run([os.environ.get('BASH', 'bash')],
                              input=prelude + stubs + '\n' + FUNCTIONS + '\n' + PART2
                              + ('\nset -e\n' if errexit else '\n') + call + ' || exit $?\n',
                              env=env, text=True, encoding='utf-8', capture_output=True, timeout=10)

    def mutations(self, result):
        return [line[4:] for line in result.stderr.splitlines()
                if line.startswith('CMD:') and line != 'CMD:status']

    def test_active_ensures_only_ssh(self):
        result = self.run_ufw(active=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(result), [COMMANDS[2]])
        self.assertIn('OK: UFW разрешает 5829/tcp', result.stdout)
        self.assertNotIn(SUCCESS, result.stdout)

    def test_active_ssh_failure(self):
        result = self.run_ufw(active=True, failure=COMMANDS[2])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.mutations(result), [COMMANDS[2]])
        self.assertIn('ERROR: Не удалось разрешить 5829/tcp в UFW', result.stderr)
        self.assertNotIn('OK:', result.stdout)
        self.assertNotIn('iPerf3:', result.stdout)

    def test_active_missing_rule_fails_closed(self):
        result = self.run_ufw(active=True, missing_rule=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('ERROR:', result.stderr)
        self.assertNotIn('OK:', result.stdout)

    def test_refusal_is_successful_noop(self):
        result = self.run_ufw(refuse=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.mutations(result), [])
        self.assertNotIn('OK:', result.stdout)

    def test_inactive_success(self):
        result = self.run_ufw()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(result), COMMANDS)
        self.assertEqual(result.stdout.count(SUCCESS), 1)

    def check_failure(self, index):
        for errexit in (False, True):
            with self.subTest(errexit=errexit):
                result = self.run_ufw(failure=COMMANDS[index], errexit=errexit)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(self.mutations(result), COMMANDS[:index + 1])
                self.assertIn('ERROR:', result.stderr)
                self.assertNotIn('OK:', result.stdout)
                self.assertNotIn('iPerf3:', result.stdout)

    def test_deny_incoming_failure(self): self.check_failure(0)
    def test_allow_outgoing_failure(self): self.check_failure(1)
    def test_allow_ssh_failure(self): self.check_failure(2)
    def test_allow_http_failure(self): self.check_failure(3)
    def test_allow_https_failure(self): self.check_failure(4)
    def test_enable_failure(self): self.check_failure(5)

    def test_real_failures_propagate_through_part2(self):
        for active, commands in ((False, COMMANDS), (True, [COMMANDS[2]])):
            for command in commands:
                for errexit in (False, True):
                    with self.subTest(active=active, command=command, errexit=errexit):
                        result = self.run_ufw(active=active, failure=command, part2=True, errexit=errexit)
                        self.assertEqual(result.returncode, 1, result.stderr)
                        self.assertNotIn('Часть 2 завершена', result.stdout)
                        self.assertEqual([line[5:] for line in result.stdout.splitlines()
                                          if line.startswith('STEP:')], STEPS[:STEPS.index('configure_ufw')])

    def test_iperf_success_and_each_failure(self):
        cases = [
            ('1', ['allow 5201/tcp comment temporary iperf3', 'allow 5201/udp comment temporary iperf3'], 'Закройте 5201'),
            ('2', ['allow from 192.0.2.1 to any port 5201 proto tcp', 'allow from 192.0.2.1 to any port 5201 proto udp'], 'iPerf3 разрешён только'),
            ('3', ['--force delete allow 5201/tcp', '--force delete allow 5201/udp'], 'Общие правила 5201 удалены'),
        ]
        for action, commands, success in cases:
            with self.subTest(action=action, success=True):
                result = self.run_ufw(refuse=True, action=action)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.mutations(result), commands)
                self.assertIn(success, result.stdout)
            for index, command in enumerate(commands):
                for errexit in (False, True):
                    with self.subTest(action=action, failure=command, errexit=errexit):
                        result = self.run_ufw(refuse=True, action=action, failure=command,
                                              part2=True, errexit=errexit)
                        self.assertEqual(result.returncode, 1, result.stderr)
                        self.assertEqual(self.mutations(result), commands[:index + 1])
                        self.assertIn('ERROR:', result.stderr)
                        self.assertNotIn(success, result.stdout)
                        self.assertNotIn('Часть 2 завершена', result.stdout)
                        self.assertNotIn('STEP:configure_shell', result.stdout)


if __name__ == '__main__':
    unittest.main()
